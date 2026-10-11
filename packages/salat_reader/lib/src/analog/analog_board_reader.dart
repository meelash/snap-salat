import 'dart:math' as math;

import '../labeling.dart';
import '../models.dart';
import '../raster.dart';
import 'face_detector.dart';
import 'hand_reader.dart';

/// Optional knowledge about a specific board, e.g. from its masjid's
/// registry entry, that removes guesswork.
class AnalogLayout {
  /// Reading order of the prayer clocks (excluding a current-time clock).
  final ReadingOrder? order;

  /// The prayers in that reading order.
  final List<Prayer>? sequence;

  /// Whether the board has a larger clock showing the current time.
  final bool? hasCurrentTimeClock;

  const AnalogLayout({this.order, this.sequence, this.hasCurrentTimeClock});
}

/// Reads boards made of analog clocks, one per prayer, optionally with a
/// bigger clock showing the current time.
class AnalogBoardReader {
  static const id = 'analog-clocks';

  final FaceDetector detector;
  final HandReader hands;

  AnalogBoardReader({FaceDetector? detector, HandReader? hands})
      : detector = detector ?? FaceDetector(),
        hands = hands ?? HandReader();

  BoardReading read(Raster raster,
      {CaptureTime? captured, AnalogLayout? layout, List<String>? debug}) {
    final warnings = <String>[];
    final faces = detector.detect(raster, debug: debug);
    if (faces.isEmpty) {
      return BoardReading(
        reader: id,
        times: [],
        warnings: ['No clock faces found.'],
        imageWidth: raster.width,
        imageHeight: raster.height,
      );
    }

    // A clearly bigger clock is the current-time clock.
    ClockFace? currentFace;
    var prayerFaces = faces;
    if (faces.length >= 3 && layout?.hasCurrentTimeClock != false) {
      final others = [for (final f in faces.skip(1)) f.radius]..sort();
      final median = others[others.length ~/ 2];
      if (faces.first.radius > 1.3 * median ||
          layout?.hasCurrentTimeClock == true) {
        currentFace = faces.first;
        prayerFaces = faces.sublist(1);
      }
    }

    final roll = _estimateRoll(prayerFaces);
    debug?.add('camera roll ${roll.toStringAsFixed(2)}°');

    // Read every clock. One we can't read still occupies its place in the
    // layout, so it keeps the others' labels right; round things that
    // aren't dials at all (glare, lamps) are dropped.
    final slotFaces = <ClockFace>[];
    final readings = <ClockTimeReading?>[];
    for (final f in prayerFaces) {
      final r = hands.read(raster, f, rollDegrees: roll, debug: debug);
      if (r == null && !hands.isDial(raster, f)) continue;
      slotFaces.add(r?.face ?? f);
      readings.add(r);
    }

    Labelling label() => labelSlots(
          [
            for (var i = 0; i < slotFaces.length; i++)
              Slot(slotFaces[i].cx, slotFaces[i].cy, slotFaces[i].radius,
                  readings[i]?.minutes12)
          ],
          order: layout?.order,
          sequence: layout?.sequence,
        );
    var labelling = label();
    // The hands alone can leave two readings nearly tied (e.g. glare hides
    // a tip). Once we know which prayer a clock is, its usual time breaks
    // the tie; then label again with the improved readings.
    var changed = false;
    for (var i = 0; i < readings.length; i++) {
      final prayer = labelling.labels[i];
      final r = readings[i];
      if (prayer == null || r == null) continue;
      final costs = [
        for (final h in r.hypotheses)
          h.cost + 2 * windowPenalty(prayer, to24h(prayer, h.minutes12))
      ];
      var best = 0;
      for (var k = 1; k < costs.length; k++) {
        if (costs[k] < costs[best]) best = k;
      }
      if (best != r.chosen) {
        var margin = 4.0;
        for (var k = 0; k < costs.length; k++) {
          if (k != best) margin = math.min(margin, costs[k] - costs[best]);
        }
        final updated = r.choose(best, margin: margin);
        debug?.add('${prayer.name}: ${r.label} -> ${updated.label} '
            '(fits the usual time better)');
        readings[i] = updated;
        changed = true;
      }
    }
    if (changed) labelling = label();
    if (!labelling.confident) {
      warnings.add("Couldn't be sure which clock is which prayer. "
          'Please check the labels.');
    }

    final times = <TimeReading>[];
    final missing = <MissingReading>[];
    for (var i = 0; i < readings.length; i++) {
      final r = readings[i];
      final prayer = labelling.labels[i];
      if (r == null) {
        missing.add(MissingReading(prayer, _region(slotFaces[i]),
            "Couldn't see this clock's hands (glare or reflection?)."));
        continue;
      }
      final minutes =
          prayer == null ? r.minutes12 : to24h(prayer, r.minutes12);
      times.add(TimeReading(
        prayer: prayer,
        kind: prayer == Prayer.sunrise ? TimeKind.adhan : TimeKind.iqamah,
        time: Hm.fromMinutes(minutes),
        confidence: r.confidence * (labelling.confident ? 1 : 0.6),
        region: _region(r.face),
        detail: r.toString(),
      ));
    }
    times.sort((a, b) {
      final pa = a.prayer?.index ?? 99, pb = b.prayer?.index ?? 99;
      return pa.compareTo(pb);
    });

    TimeReading? displayClock;
    if (currentFace != null) {
      final r = hands.read(raster, currentFace, rollDegrees: roll, debug: debug);
      if (r != null) {
        // Pick AM/PM from the photo time when we have one.
        var minutes = r.minutes12;
        if (captured != null) {
          final shot = captured.local.hour * 60 + captured.local.minute;
          if ((minutes + 720 - shot).abs() < (minutes - shot).abs()) {
            minutes += 720;
          }
          final diff = _clockDiff(minutes, shot);
          if (diff.abs() > 10) {
            warnings.add('The board clock shows ${Hm.fromMinutes(minutes).to12h()} '
                'but the photo was taken at ${Hm.fromMinutes(shot).to12h()}. '
                'Is this an old photo, or is the board clock wrong?');
          }
        }
        displayClock = TimeReading(
          prayer: null,
          kind: TimeKind.adhan,
          time: Hm.fromMinutes(minutes),
          confidence: r.confidence,
          region: _region(r.face),
          detail: r.toString(),
        );
      }
    }

    return BoardReading(
      reader: id,
      times: times,
      displayClock: displayClock,
      missing: missing,
      warnings: warnings,
      imageWidth: raster.width,
      imageHeight: raster.height,
    );
  }

  /// Camera roll in degrees (clockwise positive), from clocks that sit in
  /// the same row: rows of a board are horizontal.
  static double _estimateRoll(List<ClockFace> faces) {
    final angles = <double>[];
    for (var i = 0; i < faces.length; i++) {
      for (var j = 0; j < faces.length; j++) {
        final a = faces[i], b = faces[j];
        if (b.cx <= a.cx) continue;
        final dx = b.cx - a.cx, dy = b.cy - a.cy;
        final deg = math.atan2(dy, dx) * 180 / math.pi;
        // Same row: nearly horizontal and similar size.
        if (deg.abs() < 12 && (a.radius - b.radius).abs() < 0.25 * a.radius) {
          angles.add(deg);
        }
      }
    }
    if (angles.isEmpty) return 0;
    angles.sort();
    return angles[angles.length ~/ 2];
  }

  /// Signed difference in minutes, wrapped to ±12h.
  static int _clockDiff(int a, int b) {
    var d = (a - b) % 1440;
    if (d > 720) d -= 1440;
    return d;
  }

  static Region _region(ClockFace f) {
    final (major, _) = f.axes;
    return Region(f.cx - major, f.cy - major, 2 * major, 2 * major,
        oval: true);
  }
}
