import 'dart:math' as math;
import 'dart:typed_data';

import '../raster.dart';

/// A detected clock face: an ellipse in source-image pixels.
///
/// The ellipse is stored as the symmetric 2x2 matrix [m00] [m01] [m11] that
/// maps the unit circle onto it, which lets hand reading undo mild
/// perspective. The ellipse is the outer edge of the clock (usually the
/// outside of the bezel), not the printed dial.
class ClockFace {
  final double cx, cy;
  final double m00, m01, m11;

  /// Fraction of the rim with a clean edge, 0..1.
  final double support;

  const ClockFace(this.cx, this.cy, this.m00, this.m01, this.m11,
      {this.support = 1});

  /// Semi-axes (major, minor).
  (double, double) get axes {
    final tr = m00 + m11, det = m00 * m11 - m01 * m01;
    final d = math.sqrt(math.max(0, tr * tr / 4 - det));
    return (tr / 2 + d, tr / 2 - d);
  }

  double get radius {
    final (a, b) = axes;
    return math.sqrt(a * b);
  }

  /// Image position of the point at normalized radius [rho] (1 = rim) and
  /// clock angle [deg] (0 = 12 o'clock, clockwise).
  (double, double) at(double rho, double deg) {
    final t = deg * math.pi / 180;
    final u = rho * math.sin(t), v = -rho * math.cos(t);
    return (cx + m00 * u + m01 * v, cy + m01 * u + m11 * v);
  }

  /// Normalized radius of image point (x, y); 1 is on the rim.
  double rhoOf(double x, double y) {
    final det = m00 * m11 - m01 * m01;
    final dx = x - cx, dy = y - cy;
    final u = (m11 * dx - m01 * dy) / det;
    final v = (-m01 * dx + m00 * dy) / det;
    return math.sqrt(u * u + v * v);
  }

  ClockFace scaled(double s) =>
      ClockFace(cx * s, cy * s, m00 * s, m01 * s, m11 * s, support: support);

  /// The same ellipse shape centred on a new point.
  ClockFace recentred(double x, double y) =>
      ClockFace(x, y, m00, m01, m11, support: support);

  @override
  String toString() {
    final (a, b) = axes;
    return 'ClockFace(${cx.toStringAsFixed(0)}, ${cy.toStringAsFixed(0)}, '
        'axes ${a.toStringAsFixed(0)}/${b.toStringAsFixed(0)}, '
        'support ${support.toStringAsFixed(2)})';
  }
}

/// Finds round clock faces with a gradient Hough transform.
///
/// Brightness thresholds are unreliable on prayer boards: the dials sit
/// behind glass that reflects windows and lights. Edges survive that, so:
///  1. every strong edge votes for centres along its gradient direction;
///  2. each accumulator peak casts rays and takes the strongest
///     bright-to-dark edge on each ray (normally the rim against the board);
///  3. an ellipse is fitted to those points, dropping outliers, and kept if
///     enough of the rim agrees and the inside is bright like a dial.
class FaceDetector {
  /// Working resolution for detection (longest side, pixels).
  final int workSize;

  FaceDetector({this.workSize = 800});

  List<ClockFace> detect(Raster source, {List<String>? debug}) {
    final work = source.downscaled(workSize);
    final scale = source.width / work.width;
    final w = work.width, h = work.height;
    final lum = _blur(_toFloat(work.luminance()), w, h);

    // Sobel gradients.
    final gx = Float32List(w * h), gy = Float32List(w * h);
    final mag = Float32List(w * h);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final p = y * w + x;
        final a = lum[p - w - 1], b = lum[p - w], c = lum[p - w + 1];
        final d = lum[p - 1], f = lum[p + 1];
        final g = lum[p + w - 1], i = lum[p + w], j = lum[p + w + 1];
        final sx = (c + 2 * f + j - a - 2 * d - g) / 8;
        final sy = (g + 2 * i + j - a - 2 * b - c) / 8;
        gx[p] = sx;
        gy[p] = sy;
        mag[p] = math.sqrt(sx * sx + sy * sy);
      }
    }

    // Thin edges with non-maximum suppression along the gradient.
    const edgeThreshold = 8.0;
    final edges = <int>[];
    for (var y = 2; y < h - 2; y++) {
      for (var x = 2; x < w - 2; x++) {
        final p = y * w + x;
        final m = mag[p];
        if (m < edgeThreshold) continue;
        final ox = (gx[p] / m).round(), oy = (gy[p] / m).round();
        if (m < mag[p + oy * w + ox] || m < mag[p - oy * w - ox]) continue;
        edges.add(p);
      }
    }

    // Vote along both gradient directions, into one accumulator per
    // radius band. Each band's cells grow with the radius, so a large clock
    // seen at an angle (an ellipse, whose centre votes smear by roughly the
    // difference of its axes) still forms one sharp peak.
    final minR = math.max(8, math.min(w, h) ~/ 60);
    final maxR = math.min(w, h) ~/ 2;
    final bands = <_Band>[];
    for (var lo = minR; lo <= maxR; lo = (lo * 1.6).ceil()) {
      final hi = math.min(maxR, (lo * 1.6).ceil() - 1);
      final cell = math.max(1, lo ~/ 14);
      bands.add(_Band(lo, hi, cell, (w / cell).ceil(), (h / cell).ceil()));
    }
    for (final p in edges) {
      final x0 = p % w, y0 = p ~/ w;
      final ux = gx[p] / mag[p], uy = gy[p] / mag[p];
      for (var s = -1; s <= 1; s += 2) {
        var band = 0;
        for (var r = minR; r <= maxR; r++) {
          final x = x0 + s * ux * r, y = y0 + s * uy * r;
          if (x < 0 || y < 0 || x >= w || y >= h) break;
          while (r > bands[band].hi) {
            band++;
          }
          final b = bands[band];
          // Weight by 1/r so big and small clocks compete fairly.
          b.acc[(y ~/ b.cell) * b.w + x ~/ b.cell] += 1 / r;
        }
      }
    }

    // Local maxima of every band, strongest first.
    final peaks = <(double, double, double, _Band)>[];
    for (final b in bands) {
      final smooth = _blur(b.acc, b.w, b.h);
      const nms = 2;
      for (var y = nms; y < b.h - nms; y++) {
        for (var x = nms; x < b.w - nms; x++) {
          final v = smooth[y * b.w + x];
          if (v < 0.5) continue;
          var isMax = true;
          for (var dy = -nms; dy <= nms && isMax; dy++) {
            for (var dx = -nms; dx <= nms; dx++) {
              if (smooth[(y + dy) * b.w + x + dx] > v) {
                isMax = false;
                break;
              }
            }
          }
          if (isMax) {
            peaks.add(((x + 0.5) * b.cell, (y + 0.5) * b.cell, v, b));
          }
        }
      }
    }
    peaks.sort((a, b) => b.$3.compareTo(a.$3));

    final faces = <ClockFace>[];
    for (final (px, py, votes, band) in peaks.take(80)) {
      if (faces.any((f) => f.rhoOf(px, py) < 0.6)) continue;
      final face = _fit(px, py, edges, gx, gy, mag, lum, w, h,
          math.max(minR, (band.lo * 0.8).floor()),
          math.min(maxR, (band.hi * 1.25).ceil()), debug, votes);
      if (face == null) continue;
      if (faces.any((f) => f.rhoOf(face.cx, face.cy) < 0.6)) continue;
      faces.add(face);
    }
    // Nesting: something small inside a clock is a digit ("0" of "10") or
    // the hub, so drop it; but a clock never contains clocks of comparable
    // size, so an outer "face" around those is spurious.
    final drop = <ClockFace>{};
    for (final outer in faces) {
      for (final inner in faces) {
        if (identical(inner, outer) || inner.radius >= outer.radius) continue;
        if (outer.rhoOf(inner.cx, inner.cy) >= 1) continue;
        drop.add(inner.radius < 0.25 * outer.radius ? inner : outer);
      }
    }
    final kept = faces.where((f) => !drop.contains(f)).toList()
      ..sort((a, b) => b.radius.compareTo(a.radius));
    return [for (final f in kept) f.scaled(scale)];
  }

  /// Picks a radius for the centre at ([px],[py]), then fits an ellipse.
  ClockFace? _fit(
      double px,
      double py,
      List<int> edges,
      Float32List gx,
      Float32List gy,
      Float32List mag,
      Float32List lum,
      int w,
      int h,
      int minR,
      int maxR,
      List<String>? debug,
      double votes) {
    // Radial edge support at each radius: fraction of the circumference
    // covered by edges whose gradient points along the radius.
    final support = Float64List(maxR + 2);
    for (final p in edges) {
      final dx = p % w - px, dy = p ~/ w - py;
      final r = math.sqrt(dx * dx + dy * dy);
      if (r < minR || r > maxR) continue;
      final cos = (dx * gx[p] + dy * gy[p]) / (r * mag[p]);
      if (cos.abs() > 0.9) support[r.round()] += 1;
    }
    var bestR = 0;
    var bestScore = 0.0;
    for (var r = minR; r <= maxR; r++) {
      // Sum over a few percent of the radius: the centre may be off a
      // little (coarse cells, ellipses), which spreads the rim's support.
      final k = math.max(1, (r * 0.04).round());
      var sum = 0.0;
      for (var d = -k; d <= k; d++) {
        if (r + d >= 0 && r + d < support.length) sum += support[r + d];
      }
      final s = sum / (2 * math.pi * r);
      // Prefer the outermost strong circle (the rim), not inner rings of
      // numerals or ticks: later radii win near-ties.
      if (s >= 0.35 && s >= bestScore * 0.8) {
        bestR = r;
        bestScore = math.max(bestScore, s);
      }
    }
    if (bestR == 0) return null;

    // Ray casting: strongest bright-to-dark step near the chosen radius.
    const rays = 120;
    final xs = <double>[], ys = <double>[];
    for (var k = 0; k < rays; k++) {
      final t = 2 * math.pi * k / rays;
      final cx = math.cos(t), cy = math.sin(t);
      var best = 0.0, bestAt = -1.0;
      for (var r = bestR * 0.8; r <= bestR * 1.2; r += 0.5) {
        final inner =
            _bilinear(lum, w, h, px + cx * (r - 1), py + cy * (r - 1));
        final outer =
            _bilinear(lum, w, h, px + cx * (r + 1), py + cy * (r + 1));
        final drop = inner - outer;
        if (drop > best) {
          best = drop;
          bestAt = r;
        }
      }
      if (best > 6) {
        xs.add(px + cx * bestAt);
        ys.add(py + cy * bestAt);
      }
    }
    if (xs.length < rays * 0.5) return null;

    ClockFace? face;
    var inliers = List<int>.generate(xs.length, (i) => i);
    for (var iter = 0; iter < 4; iter++) {
      face = _fitConic(
          [for (final i in inliers) xs[i]], [for (final i in inliers) ys[i]]);
      if (face == null) return null;
      // Keep points within 6% of the rim.
      final next = <int>[];
      for (var i = 0; i < xs.length; i++) {
        if ((face.rhoOf(xs[i], ys[i]) - 1).abs() < 0.06) next.add(i);
      }
      if (next.length < 6) return null;
      inliers = next;
    }
    face = face!;
    final rimSupport = inliers.length / rays;
    final (major, minor) = face.axes;

    // The dial should be brighter than the surround just outside the rim.
    final inside = <double>[], outside = <double>[];
    for (var k = 0; k < 72; k++) {
      final deg = k * 5.0;
      for (final rho in [0.55, 0.65, 0.75]) {
        final (x, y) = face.at(rho, deg);
        inside.add(_bilinear(lum, w, h, x, y));
      }
      final (x, y) = face.at(1.12, deg);
      outside.add(_bilinear(lum, w, h, x, y));
    }
    final inMed = _median(inside), outMed = _median(outside);

    final ok = rimSupport > 0.55 &&
        minor / major > 0.7 &&
        major >= minR &&
        inMed > 90 &&
        inMed > outMed + 15 &&
        face.cx > 0 &&
        face.cy > 0 &&
        face.cx < w &&
        face.cy < h;
    debug?.add(
        'peak ${px.toInt()},${py.toInt()} votes ${votes.toStringAsFixed(1)} '
        'r=$bestR score ${bestScore.toStringAsFixed(2)} -> $face '
        'rim ${rimSupport.toStringAsFixed(2)} in ${inMed.toStringAsFixed(0)} '
        'out ${outMed.toStringAsFixed(0)} ${ok ? 'FACE' : 'reject'}');
    if (!ok) return null;
    return ClockFace(face.cx, face.cy, face.m00, face.m01, face.m11,
        support: rimSupport);
  }

  /// Least-squares conic fit Ax² + Bxy + Cy² + Dx + Ey = 1 (coordinates
  /// centred and scaled for conditioning), converted to centre + the
  /// matrix mapping the unit circle onto the ellipse.
  static ClockFace? _fitConic(List<double> xs, List<double> ys) {
    final n = xs.length;
    if (n < 6) return null;
    var mx = 0.0, my = 0.0;
    for (var i = 0; i < n; i++) {
      mx += xs[i];
      my += ys[i];
    }
    mx /= n;
    my /= n;
    var sc = 0.0;
    for (var i = 0; i < n; i++) {
      sc += math.sqrt(math.pow(xs[i] - mx, 2) + math.pow(ys[i] - my, 2));
    }
    sc = sc / n;
    final ata = List.generate(5, (_) => Float64List(5));
    final atb = Float64List(5);
    for (var i = 0; i < n; i++) {
      final x = (xs[i] - mx) / sc, y = (ys[i] - my) / sc;
      final row = [x * x, x * y, y * y, x, y];
      for (var a = 0; a < 5; a++) {
        atb[a] += row[a];
        for (var b = 0; b < 5; b++) {
          ata[a][b] += row[a] * row[b];
        }
      }
    }
    final sol = _solve(ata, atb);
    if (sol == null) return null;
    final a = sol[0], b = sol[1], c = sol[2], d = sol[3], e = sol[4];
    // Q = [[a, b/2], [b/2, c]], centre = -Q⁻¹[d, e]/2.
    final q00 = a, q01 = b / 2, q11 = c;
    final qdet = q00 * q11 - q01 * q01;
    if (qdet <= 0 || q00 <= 0) return null;
    final x0 = -(q11 * d - q01 * e) / (2 * qdet);
    final y0 = -(-q01 * d + q00 * e) / (2 * qdet);
    final k = 1 + q00 * x0 * x0 + 2 * q01 * x0 * y0 + q11 * y0 * y0;
    if (k <= 0) return null;
    // P = Q/k; the ellipse is uᵀPu = 1, so M = P^(-1/2).
    final p00 = q00 / k, p01 = q01 / k, p11 = q11 / k;
    final s = math.sqrt(p00 * p11 - p01 * p01);
    final t = math.sqrt(p00 + p11 + 2 * s);
    // sqrt(P), then its inverse.
    final r00 = (p00 + s) / t, r01 = p01 / t, r11 = (p11 + s) / t;
    final rdet = r00 * r11 - r01 * r01;
    final m00 = r11 / rdet, m01 = -r01 / rdet, m11 = r00 / rdet;
    return ClockFace(
        mx + x0 * sc, my + y0 * sc, m00 * sc, m01 * sc, m11 * sc);
  }

  /// Gaussian elimination with partial pivoting.
  static List<double>? _solve(List<Float64List> a, Float64List b) {
    final n = b.length;
    final m = [
      for (var i = 0; i < n; i++) [...a[i], b[i]]
    ];
    for (var c = 0; c < n; c++) {
      var piv = c;
      for (var r = c + 1; r < n; r++) {
        if (m[r][c].abs() > m[piv][c].abs()) piv = r;
      }
      if (m[piv][c].abs() < 1e-12) return null;
      final tmp = m[c];
      m[c] = m[piv];
      m[piv] = tmp;
      for (var r = 0; r < n; r++) {
        if (r == c) continue;
        final f = m[r][c] / m[c][c];
        for (var k = c; k <= n; k++) {
          m[r][k] -= f * m[c][k];
        }
      }
    }
    return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
  }

  static Float32List _toFloat(Uint8List v) {
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i].toDouble();
    }
    return out;
  }

  /// Two passes of a separable 3-tap box blur (≈ small Gaussian).
  static Float32List _blur(Float32List src, int w, int h) {
    var a = src;
    for (var pass = 0; pass < 2; pass++) {
      final t = Float32List(w * h), out = Float32List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = y * w + x;
          final l = x > 0 ? a[p - 1] : a[p], r = x < w - 1 ? a[p + 1] : a[p];
          t[p] = (l + a[p] + r) / 3;
        }
      }
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = y * w + x;
          final u = y > 0 ? t[p - w] : t[p], d = y < h - 1 ? t[p + w] : t[p];
          out[p] = (u + t[p] + d) / 3;
        }
      }
      a = out;
    }
    return a;
  }

  static double _bilinear(Float32List a, int w, int h, double x, double y) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > w - 1.001) x = w - 1.001;
    if (y > h - 1.001) y = h - 1.001;
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final p = y0 * w + x0;
    return a[p] * (1 - fx) * (1 - fy) +
        a[p + 1] * fx * (1 - fy) +
        a[p + w] * (1 - fx) * fy +
        a[p + w + 1] * fx * fy;
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }
}

/// Hough accumulator for radii [lo]..[hi], with cells of [cell] pixels.
class _Band {
  final int lo, hi, cell, w, h;
  final Float32List acc;
  _Band(this.lo, this.hi, this.cell, this.w, this.h) : acc = Float32List(w * h);
}
