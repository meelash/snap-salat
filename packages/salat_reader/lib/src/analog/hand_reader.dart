import 'dart:math' as math;
import 'dart:typed_data';

import '../raster.dart';
import 'face_detector.dart';

/// A hand-like dark streak radiating from the pivot.
class HandCandidate {
  /// Clock angle in degrees, 0 = 12 o'clock, clockwise.
  final double angle;

  /// Reach from the pivot, as a fraction of the clock radius.
  final double length;

  /// Approximate width as a fraction of the clock radius.
  final double width;

  /// The hand disappears into blown-out glare, so [length] is only a
  /// lower bound.
  final bool censored;

  /// Directions of the inner (near the hub) and outer parts, if measured.
  final double? innerAngle, outerAngle;

  const HandCandidate(this.angle, this.length, this.width,
      {this.censored = false, this.innerAngle, this.outerAngle});

  HandCandidate rotated(double degrees) {
    double r(double a) => (a - degrees) % 360;
    return HandCandidate(r(angle), length, width,
        censored: censored,
        innerAngle: innerAngle == null ? null : r(innerAngle!),
        outerAngle: outerAngle == null ? null : r(outerAngle!));
  }

  @override
  String toString() => '${angle.toStringAsFixed(1)}° '
      'len ${length.toStringAsFixed(2)}${censored ? '+' : ''} '
      'w ${width.toStringAsFixed(3)}';
}

/// One interpretation of a clock's hands.
class ClockHypothesis {
  /// Minutes past 12:00, 0..719.
  final int minutes12;

  /// Negative log-likelihood-like score; lower is better.
  final double cost;

  /// Hour-hand angle error implied by the minute hand, in degrees.
  final double residual;
  final HandCandidate hourHand, minuteHand;
  final bool handsOverlap;

  const ClockHypothesis(this.minutes12, this.cost, this.residual,
      this.hourHand, this.minuteHand, this.handsOverlap);
}

/// The time shown by one analog clock.
class ClockTimeReading {
  /// The clock, re-centred on the detected pivot.
  final ClockFace face;

  /// Interpretations, best first, one per distinct time.
  final List<ClockHypothesis> hypotheses;
  final List<HandCandidate> candidates;

  /// Which of [hypotheses] is chosen (the board reader may pick another
  /// when the prayer's usual time favours it).
  final int chosen;

  /// When outside knowledge picked [chosen], how much better it scored
  /// than the runner-up with that knowledge included.
  final double? margin;

  const ClockTimeReading(this.face, this.hypotheses, this.candidates,
      {this.chosen = 0, this.margin});

  ClockTimeReading choose(int i, {required double margin}) =>
      ClockTimeReading(face, hypotheses, candidates, chosen: i, margin: margin);

  ClockHypothesis get best => hypotheses[chosen];

  /// Minutes past 12:00 (0..719).
  int get minutes12 => best.minutes12;
  bool get handsOverlap => best.handsOverlap;

  /// 0..1. Low when the hands disagree with each other or when another
  /// reading of the same hands is nearly as plausible.
  double get confidence {
    final err = best.residual.abs();
    final agreement = (1 - math.max(0, err - 5) / 12).clamp(0.05, 1.0);
    var margin = this.margin ?? 4.0;
    if (this.margin == null) {
      for (var i = 0; i < hypotheses.length; i++) {
        if (i != chosen) {
          margin = math.min(margin, hypotheses[i].cost - best.cost);
        }
      }
    }
    final distinct = 1 - math.exp(-1.5 * math.max(0, margin));
    // Overlapping hands, or a reading that needed the prayer's usual time
    // to settle, deserve a second look.
    final overlapCap = handsOverlap || this.margin != null ? 0.75 : 1.0;
    return math.min(overlapCap, agreement * distinct).toDouble();
  }

  String get label {
    final h = minutes12 ~/ 60, m = minutes12 % 60;
    return '${h == 0 ? 12 : h}:${m.toString().padLeft(2, '0')}';
  }

  @override
  String toString() => '$label (conf ${confidence.toStringAsFixed(2)}'
      '${handsOverlap ? ', overlapping hands' : ''}, '
      'residual ${best.residual.toStringAsFixed(1)}°) '
      'hour=${best.hourHand} min=${best.minuteHand}'
      '${hypotheses.length > 1 ? ' alt ${hypotheses.skip(1).take(2).map((h) => '${h.minutes12 ~/ 60}:${(h.minutes12 % 60).toString().padLeft(2, '0')}@${h.cost.toStringAsFixed(2)}').join(' ')} vs ${best.cost.toStringAsFixed(2)}' : ''}';
}

/// Reads the hour and minute hands of one clock.
///
///  1. The dial is resampled into a canonical square where it is a circle
///     of radius [_rc], which also undoes mild perspective.
///  2. Darkness is measured with a black top-hat (grey closing minus the
///     image): thin dark strokes stand out whatever the local brightness,
///     so reflections and glare on the glass matter much less.
///  3. For each angle we measure how far a continuous dark run reaches from
///     the hub. Only rays along a hand stay dark for long, so hands are
///     sharp peaks; numerals and logos are not connected to the hub.
///  4. The pivot is refined by fitting straight lines to the two strongest
///     hands and intersecting them, then hands are measured again from it.
///  5. Hour/minute roles come from consistency: the hour hand must sit at
///     30·h + m/2 degrees for the minute m the minute hand shows.
class HandReader {
  static const _rc = 150;
  static const _thetaBins = 720; // 0.5° each
  static const _rhoStep = 1 / _rc;
  static const _rhoMax = 0.9;

  /// Whether [face] looks like a real dial (has numerals or ticks).
  bool isDial(Raster src, ClockFace face) =>
      _Dial.sample(src, face, _rc).texture >= _minTexture;

  static const _minTexture = 0.015;

  ClockTimeReading? read(Raster src, ClockFace face,
      {double rollDegrees = 0, List<String>? debug}) {
    final dial = _Dial.sample(src, face, _rc);
    final texture = dial.texture;
    debug?.add('  dial texture ${texture.toStringAsFixed(3)}');
    if (texture < _minTexture) return null;
    var px = _rc.toDouble(), py = _rc.toDouble();
    var hands = _findHands(dial, px, py, hubLimit: 0.2);
    debug?.add('  initial candidates: ${hands.join(' | ')}');
    for (var pass = 0; pass < 3; pass++) {
      // Only well-traced hands give a reliable line.
      final traced = hands.where((h) => h.span >= 0.25).toList();
      if (traced.length < 2) break;
      final pivot = _intersect(traced[0], traced[1], px, py);
      if (pivot == null) break;
      final moved = math.sqrt(math.pow(pivot.$1 - px, 2) + math.pow(pivot.$2 - py, 2));
      px = pivot.$1;
      py = pivot.$2;
      hands = _findHands(dial, px, py, hubLimit: 0.12);
      debug?.add('  pivot (${px.toStringAsFixed(1)}, ${py.toStringAsFixed(1)}): '
          '${hands.join(' | ')}');
      if (moved < 0.5) break;
    }
    // Report the pivot in image coordinates.
    final u = (px - _rc) / _rc, v = (py - _rc) / _rc;
    final pivoted = face.recentred(face.cx + face.m00 * u + face.m01 * v,
        face.cy + face.m01 * u + face.m11 * v);
    debug?.add('  pivot offset (${u.toStringAsFixed(3)}, '
        '${v.toStringAsFixed(3)}) candidates: ${hands.join(' | ')}');
    if (hands.isEmpty) return null;
    final adjusted = [
      for (final h in hands)
        h.rotated(rollDegrees)
    ];
    return _interpret(pivoted, adjusted);
  }

  /// Where the centre lines of two hands cross, if they are far enough
  /// from parallel and the crossing is near the current pivot.
  (double, double)? _intersect(
      _Hand a, _Hand b, double px, double py) {
    final cross = a.dx * b.dy - a.dy * b.dx; // sine of the angle between
    double x, y;
    if (cross.abs() < 0.5) {
      // Nearly opposite hands share one line: the pivot is on it, so move
      // the pivot onto it (its position along the line doesn't matter).
      final t = (px - a.x) * a.dx + (py - a.y) * a.dy;
      x = a.x + t * a.dx;
      y = a.y + t * a.dy;
    } else {
      final s = ((b.x - a.x) * b.dy - (b.y - a.y) * b.dx) / cross;
      x = a.x + s * a.dx;
      y = a.y + s * a.dy;
    }
    if (math.pow(x - px, 2) + math.pow(y - py, 2) > math.pow(0.15 * _rc, 2)) {
      return null;
    }
    return (x, y);
  }

  /// Chooses hour/minute roles from the candidates.
  ///
  /// Each hypothesis is scored like a negative log-likelihood:
  ///  - the hour hand should sit where the minute hand puts it (σ ≈ 5°;
  ///    cheap movements are often a few degrees off);
  ///  - the minute hand should be ~0.2 radius longer (σ ≈ 0.2, because
  ///    glare can cut a hand short and a numeral can extend one);
  ///  - the hour hand is usually at least as wide (capped: clutter can
  ///    inflate a measured width);
  ///  - both should be among the strongest streaks.
  /// Overlapping hands are a separate hypothesis.
  ClockTimeReading _interpret(ClockFace face, List<HandCandidate> hands) {
    final longest = hands.map((h) => h.length).reduce(math.max);
    final all = <ClockHypothesis>[];
    double sq(double x) => x * x;

    final top = hands.take(4).toList();
    for (var i = 0; i < top.length; i++) {
      for (var j = 0; j < top.length; j++) {
        if (i == j) continue;
        final hour = top[i], minute = top[j];
        final (minutes, err) = timeFromAngles(hour.angle, minute.angle);
        var lengthGap = minute.length - hour.length - 0.2;
        // A minute hand lost in glare may be longer than it looks.
        if (minute.censored && lengthGap < 0) lengthGap = 0;
        final cost = sq(err / 5) / 2 +
            sq(lengthGap / 0.2) / 2 +
            // Width is easily inflated by clutter, so its say is capped.
            sq((minute.width - hour.width).clamp(0.0, 0.03) / 0.02) / 2 +
            sq((1 - math.min(hour.length, minute.length) / longest) / 0.5) / 2;
        all.add(ClockHypothesis(minutes, cost, err, hour, minute, false));
      }
    }

    // (Nearly) overlapping hands form a single streak. The minute and
    // hour hands coincide at multiples of 360/11 degrees; near those times
    // the streak's tip is the minute hand alone and its inner part
    // averages both hands, so hour ≈ 2·inner − outer. Unlikely if another
    // strong hand is visible elsewhere.
    for (final h in top.take(2)) {
      final other = hands
          .where((o) => _diff(o.angle, h.angle).abs() > 15)
          .fold(0.0, (m, o) => math.max(m, o.length));
      final prior = 2 +
          sq((1 - h.length / longest) / 0.3) / 2 +
          sq(other / longest / 0.2) / 2;
      final inner = h.innerAngle, outer = h.outerAngle;
      if (inner != null && outer != null && _diff(inner, outer).abs() < 12) {
        final minuteAngle = outer;
        final hourAngle = (outer + 2 * _diff(inner, outer)) % 360;
        final (minutes, err) = timeFromAngles(hourAngle, minuteAngle);
        // The hour estimate doubles the noise, hence the wider σ.
        all.add(ClockHypothesis(minutes, prior + sq(err / 8) / 2, err,
            HandCandidate(hourAngle, h.length, h.width), h, true));
      }
      const step = 360 / 11;
      final k = (h.angle / step).round() % 11;
      final dev = _diff(h.angle, k * step);
      all.add(ClockHypothesis((k * 720 / 11).round() % 720,
          prior + 0.5 + sq(dev / 5) / 2, dev, h, h, true));
    }

    // Keep the best hypothesis per distinct time (±2 minutes).
    all.sort((a, b) => a.cost.compareTo(b.cost));
    final distinct = <ClockHypothesis>[];
    for (final h in all) {
      final same = distinct.any((d) {
        final diff = (d.minutes12 - h.minutes12).abs();
        return math.min(diff, 720 - diff) <= 2;
      });
      if (!same) distinct.add(h);
    }
    return ClockTimeReading(face, distinct, hands);
  }

  /// Time from hand angles as minutes past 12 (0..719), and how far the
  /// hour hand is from where the minute hand says it should be (degrees).
  static (int, double) timeFromAngles(double hourAngle, double minuteAngle) {
    final minuteOfHour = minuteAngle / 6; // 0..60
    // The hour hand advances 0.5° per minute.
    final h = ((hourAngle - minuteOfHour / 2) / 30).round() % 12;
    final err = _diff(hourAngle, h * 30 + minuteOfHour / 2);
    final total = (h * 60 + minuteOfHour).round() % 720;
    return (total, err);
  }

  /// Signed smallest difference a - b in degrees.
  static double _diff(double a, double b) {
    var d = (a - b) % 360;
    if (d > 180) d -= 360;
    return d;
  }

  /// Candidate hands around pivot ([px], [py]), longest first.
  List<_Hand> _findHands(_Dial dial, double px, double py,
      {required double hubLimit}) {
    const n = _thetaBins;
    final steps = (_rhoMax / _rhoStep).floor();
    final dark = Uint8List(n * steps);
    for (var t = 0; t < n; t++) {
      final a = t * 2 * math.pi / n;
      final s = math.sin(a), c = math.cos(a);
      for (var j = 0; j < steps; j++) {
        final r = (j + 0.5) * _rhoStep * _rc;
        if (dial.isHandDark(px + r * s, py - r * c)) dark[t * steps + j] = 1;
      }
    }

    // Reach of the dark run that starts at the hub, per angle.
    final reach = Float64List(n);
    final hubSteps = (hubLimit / _rhoStep).round();
    const maxGap = 5;
    for (var t = 0; t < n; t++) {
      var j = 0;
      while (j < hubSteps && dark[t * steps + j] == 0) {
        j++;
      }
      if (j >= hubSteps) continue;
      var last = j, gap = 0;
      for (; j < steps; j++) {
        if (dark[t * steps + j] == 1) {
          last = j;
          gap = 0;
        } else if (++gap > maxGap) {
          break;
        }
      }
      reach[t] = (last + 1) * _rhoStep;
    }

    // Peaks: local maxima longer than counterweight tails.
    final hands = <_Hand>[];
    const minReach = 0.28;
    const nmsBins = 8 * n ~/ 360;
    for (var t = 0; t < n; t++) {
      final v = reach[t];
      if (v < minReach) continue;
      var isMax = true;
      for (var d = -nmsBins; d <= nmsBins; d++) {
        final o = reach[(t + d) % n];
        if (o > v || (o == v && d < 0)) {
          isMax = false;
          break;
        }
      }
      if (!isMax) continue;
      final hand = _fitHand(dial, px, py, t * 360 / n, v);
      // Shorter than a counterweight tail once fitted: not a hand.
      if (hand != null && hand.length >= 0.25) hands.add(hand);
    }
    hands.sort((a, b) => b.length.compareTo(a.length));
    // Two peaks can belong to one hand; keep the longer.
    final unique = <_Hand>[];
    for (final h in hands) {
      if (unique.every((u) => _diff(u.angle, h.angle).abs() > 6)) unique.add(h);
    }
    return unique;
  }

  /// Fits the centre line of the hand near clock angle [deg] from the
  /// pivot, by iterating: sample the cross-section every pixel along the
  /// current line, take the darkness²-weighted lateral centroid (which is
  /// the axis for solid and hollow/skeleton hands alike, and barely moved
  /// by a paler shadow), then robustly refit the line through those
  /// centroids. Crossing clutter such as reflected fences only disturbs a
  /// few cross-sections, which the robust fit discards.
  _Hand? _fitHand(
      _Dial dial, double px, double py, double deg, double reach) {
    // Current line: point (lx, ly), unit direction (ux, uy) away from pivot.
    final t0 = deg * math.pi / 180;
    var lx = px, ly = py;
    var ux = math.sin(t0), uy = -math.cos(t0);
    const half = 0.04 * _rc; // lateral half-window
    const latStep = 0.5;
    final from = 0.2 * _rc;
    final to = math.max(0.3, reach * 0.9) * _rc;

    List<(double, double, double)> centroids() {
      final out = <(double, double, double)>[];
      // Distance along the line from its point to the pivot's foot.
      final base = (px - lx) * ux + (py - ly) * uy;
      for (var r = from; r <= to; r += 1) {
        final cx = lx + (base + r) * ux, cy = ly + (base + r) * uy;
        var sw = 0.0, so = 0.0;
        for (var o = -half; o <= half; o += latStep) {
          final w = dial.darknessAt(cx - o * uy, cy + o * ux);
          if (w <= _Dial.darkThreshold) continue;
          sw += w * w;
          so += w * w * o;
        }
        if (sw < 0.05) continue;
        final off = so / sw;
        out.add((cx - off * uy, cy + off * ux, sw));
      }
      return out;
    }

    var pts = <(double, double, double)>[];
    for (var iter = 0; iter < 3; iter++) {
      pts = centroids();
      if (pts.length < 10) return null;
      final xs = [for (final p in pts) p.$1], ys = [for (final p in pts) p.$2];
      var idx = List<int>.generate(pts.length, (i) => i);
      var line = _fitLine(xs, ys, idx);
      for (var round = 0; round < 2; round++) {
        final keep = [
          for (final i in idx)
            if (((xs[i] - line.$1) * line.$4 - (ys[i] - line.$2) * line.$3)
                    .abs() <
                (round == 0 ? 0.025 : 0.012) * _rc)
              i
        ];
        if (keep.length < 8) break;
        idx = keep;
        line = _fitLine(xs, ys, idx);
      }
      var (mx, my, dx, dy) = line;
      if ((mx - px) * dx + (my - py) * dy < 0) {
        dx = -dx;
        dy = -dy;
      }
      // Don't let the line swing onto something else entirely.
      if (dx * math.sin(t0) - dy * math.cos(t0) < math.cos(15 * math.pi / 180)) {
        return null;
      }
      lx = mx;
      ly = my;
      ux = dx;
      uy = dy;
    }

    // Tip: walk along the line until the hand runs out.
    final base = (px - lx) * ux + (py - ly) * uy;
    var tip = from;
    var gap = 0.0;
    for (var r = from; r < _rhoMax * _rc; r += 1) {
      final cx = lx + (base + r) * ux, cy = ly + (base + r) * uy;
      var hit = false;
      for (var o = -0.015 * _rc; o <= 0.015 * _rc; o += 1) {
        if (dial.darknessAt(cx - o * uy, cy + o * ux) > _Dial.darkThreshold) {
          hit = true;
          break;
        }
      }
      if (hit) {
        tip = r;
        gap = 0;
      } else if ((gap += 1) > 0.035 * _rc) {
        break;
      }
    }

    // If the hand runs into blown-out glare, its tip is hidden.
    var hidden = 0, looked = 0;
    for (var r = tip + 2; r < math.min(tip + 0.12 * _rc, _rhoMax * _rc); r += 1) {
      final cx = lx + (base + r) * ux, cy = ly + (base + r) * uy;
      looked++;
      if (dial.saturatedAt(cx, cy)) hidden++;
    }
    final censored = looked > 0 && hidden > 0.4 * looked;

    // Width: lateral extent of darkness at a few points along the hand.
    final widths = <double>[];
    for (final f in [0.35, 0.5, 0.65]) {
      final r = from + (tip - from) * f;
      final cx = lx + (base + r) * ux, cy = ly + (base + r) * uy;
      double? lo, hi;
      for (var o = -0.06 * _rc; o <= 0.06 * _rc; o += latStep) {
        if (dial.darknessAt(cx - o * uy, cy + o * ux) > _Dial.darkThreshold) {
          lo ??= o;
          hi = o;
        }
      }
      if (lo != null) widths.add((hi! - lo + latStep) / _rc);
    }
    widths.sort();

    final angle = math.atan2(ux, -uy) * 180 / math.pi;
    final span = (to - from) / _rc;

    // Separate directions for the inner and outer parts. When the hour and
    // minute hands nearly overlap they form one streak: its outer part is
    // the minute hand alone, its inner part averages both.
    double? partAngle(double lo, double hi) {
      final xs = <double>[], ys = <double>[];
      for (final (x, y, _) in pts) {
        final r = (x - px) * ux + (y - py) * uy;
        if (r >= lo && r <= hi) {
          xs.add(x);
          ys.add(y);
        }
      }
      if (xs.length < 6) return null;
      var (_, _, dx, dy) =
          _fitLine(xs, ys, List<int>.generate(xs.length, (i) => i));
      if (dx * ux + dy * uy < 0) {
        dx = -dx;
        dy = -dy;
      }
      return (math.atan2(dx, -dy) * 180 / math.pi) % 360;
    }

    return _Hand(angle % 360, tip / _rc,
        widths.isEmpty ? 0 : widths[widths.length ~/ 2], lx, ly, ux, uy, span,
        censored: censored,
        innerAngle: partAngle(from, 0.45 * _rc),
        outerAngle: partAngle(math.max(0.5 * _rc, 0.7 * tip), tip));
  }

  /// Total least squares line through the points [idx]: (mean x, mean y,
  /// unit direction x, unit direction y).
  static (double, double, double, double) _fitLine(
      List<double> xs, List<double> ys, List<int> idx) {
    var mx = 0.0, my = 0.0;
    for (final i in idx) {
      mx += xs[i];
      my += ys[i];
    }
    mx /= idx.length;
    my /= idx.length;
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final i in idx) {
      sxx += (xs[i] - mx) * (xs[i] - mx);
      syy += (ys[i] - my) * (ys[i] - my);
      sxy += (xs[i] - mx) * (ys[i] - my);
    }
    final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return (mx, my, math.cos(theta), math.sin(theta));
  }
}

/// A hand candidate with its fitted centre line (canonical coordinates).
class _Hand extends HandCandidate {
  final double x, y, dx, dy;

  /// Length of the traced centre line, as a fraction of the radius.
  final double span;

  const _Hand(super.angle, super.length, super.width, this.x, this.y,
      this.dx, this.dy, this.span,
      {super.censored, super.innerAngle, super.outerAngle});
}

class _Dial {
  final int rc, size;
  final Float32List lum, chroma;

  /// Top-hat darkness relative to the local background, 0..1.
  final Float32List dark;

  /// [isHandDark] pixels after a small closing, so the outline of a
  /// hollow ("skeleton") hand reads as one solid streak.
  final Uint8List handMask;

  _Dial(this.rc, this.size, this.lum, this.chroma, this.dark)
      : handMask = Uint8List(size * size) {
    var mask = Float32List(size * size);
    for (var i = 0; i < mask.length; i++) {
      if (dark[i] > darkThreshold && chroma[i] < 60) mask[i] = 1;
    }
    final k = (0.027 * rc).round();
    mask = _minFilter(_maxFilter(mask, size, k), size, k);
    for (var i = 0; i < mask.length; i++) {
      handMask[i] = mask[i] > 0.5 ? 1 : 0;
    }
  }

  /// Fraction of dark pixels where numerals and ticks sit. Real dials have
  /// some; glare blobs and other round bright things have almost none.
  double get texture {
    var darkCount = 0, total = 0;
    for (var y = 0; y < size; y += 2) {
      for (var x = 0; x < size; x += 2) {
        final dx = x - rc, dy = y - rc;
        final r2 = (dx * dx + dy * dy) / (rc * rc);
        if (r2 < 0.55 * 0.55 || r2 > 0.85 * 0.85) continue;
        total++;
        if (dark[y * size + x] > darkThreshold) darkCount++;
      }
    }
    return total == 0 ? 0 : darkCount / total;
  }

  static _Dial sample(Raster src, ClockFace f, int rc) {
    final size = 2 * rc + 1;
    final lum = Float32List(size * size), chroma = Float32List(size * size);
    // Supersample when the source dial is larger than the canonical one.
    final ss = (f.radius / rc).ceil().clamp(1, 3);
    final px = Float64List(2);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var l = 0.0, c = 0.0;
        for (var sy = 0; sy < ss; sy++) {
          for (var sx = 0; sx < ss; sx++) {
            final u = (x - rc + (sx + 0.5) / ss - 0.5) / rc;
            final v = (y - rc + (sy + 0.5) / ss - 0.5) / rc;
            src.sample(f.cx + f.m00 * u + f.m01 * v,
                f.cy + f.m01 * u + f.m11 * v, px);
            l += px[0];
            c += px[1];
          }
        }
        lum[y * size + x] = l / (ss * ss);
        chroma[y * size + x] = c / (ss * ss);
      }
    }
    // Closing with a square (side ≈ 0.22 radius) wider than the hands and
    // hub erases them, so closing - image is large on thin dark strokes but
    // not on broad reflections.
    final k = (0.11 * rc).round();
    final closed = _minFilter(_maxFilter(lum, size, k), size, k);
    final dark = Float32List(size * size);
    for (var i = 0; i < dark.length; i++) {
      final bg = math.max(closed[i], 60.0);
      dark[i] = ((closed[i] - lum[i]) / bg).clamp(0.0, 1.0).toDouble();
    }
    return _Dial(rc, size, lum, chroma, dark);
  }

  static const darkThreshold = 0.22;

  /// Top-hat darkness of unsaturated pixels (so a coloured seconds hand
  /// doesn't count). Nearest-neighbour lookup in canonical coordinates.
  double handDarkness(double x, double y) {
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= size || yi >= size) return 0;
    final i = yi * size + xi;
    return chroma[i] < 60 ? dark[i] : 0;
  }

  bool isHandDark(double x, double y) {
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= size || yi >= size) return false;
    return handMask[yi * size + xi] == 1;
  }

  /// Blown-out highlight (glare), where nothing can be seen.
  bool saturatedAt(double x, double y) {
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= size || yi >= size) return false;
    return lum[yi * size + xi] > 240;
  }

  /// Bilinear [handDarkness] for sub-pixel sampling.
  double darknessAt(double x, double y) {
    if (x < 0 || y < 0 || x > size - 1.001 || y > size - 1.001) return 0;
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    double at(int xi, int yi) {
      final i = yi * size + xi;
      return chroma[i] < 60 ? dark[i] : 0;
    }

    return at(x0, y0) * (1 - fx) * (1 - fy) +
        at(x0 + 1, y0) * fx * (1 - fy) +
        at(x0, y0 + 1) * (1 - fx) * fy +
        at(x0 + 1, y0 + 1) * fx * fy;
  }

  static Float32List _maxFilter(Float32List a, int size, int k) =>
      _rankFilter(a, size, k, math.max);

  static Float32List _minFilter(Float32List a, int size, int k) =>
      _rankFilter(a, size, k, math.min);

  /// Separable square max/min filter of width 2k+1 (edges clamp).
  static Float32List _rankFilter(
      Float32List a, int size, int k, double Function(double, double) op) {
    final tmp = Float32List(a.length), out = Float32List(a.length);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var v = a[y * size + x];
        for (var d = math.max(0, x - k); d <= math.min(size - 1, x + k); d++) {
          v = op(v, a[y * size + d]);
        }
        tmp[y * size + x] = v;
      }
    }
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var v = tmp[y * size + x];
        for (var d = math.max(0, y - k); d <= math.min(size - 1, y + k); d++) {
          v = op(v, tmp[d * size + x]);
        }
        out[y * size + x] = v;
      }
    }
    return out;
  }
}

/// Development aid: points the hand finder considers dark, in image space.
List<(double, double)> debugDarkPoints(Raster src, ClockFace f) {
  const rc = HandReader._rc;
  final dial = _Dial.sample(src, f, rc);
  final out = <(double, double)>[];
  for (var y = 0; y < dial.size; y += 2) {
    for (var x = 0; x < dial.size; x += 2) {
      if (!dial.isHandDark(x.toDouble(), y.toDouble())) continue;
      final u = (x - rc) / rc, v = (y - rc) / rc;
      out.add((f.cx + f.m00 * u + f.m01 * v, f.cy + f.m01 * u + f.m11 * v));
    }
  }
  return out;
}
