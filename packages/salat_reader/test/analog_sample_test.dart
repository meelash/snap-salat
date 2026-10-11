import 'dart:io';

import 'package:salat_reader/salat_reader.dart';
import 'package:test/test.dart';

/// The real photo in sample_images/: a Hartco-style board with a big
/// current-time clock and six prayer clocks, behind reflective glass.
void main() {
  late BoardReading reading;
  late CaptureTime? captured;

  setUpAll(() {
    final bytes =
        File('../../sample_images/IMG_20261009_165338219.jpg').readAsBytesSync();
    captured = CaptureTime.fromExif(bytes);
    reading = readAnalogBoard(bytes);
  });

  test('reads where the photo was taken from EXIF GPS', () {
    final where = PhotoLocation.fromExif(
        File('../../sample_images/IMG_20261009_165338219.jpg').readAsBytesSync());
    expect(where, isNotNull);
    // Hamden, Connecticut.
    expect(where!.latitude, closeTo(41.343, 0.001));
    expect(where.longitude, closeTo(-72.927, 0.001));
  });

  test('reads the capture time from EXIF', () {
    expect(captured, isNotNull);
    expect(captured!.toIso8601(), '2026-10-09T16:53:38');
  });

  void expectTime(Prayer p, String want, {int tolerance = 1}) {
    final got = reading.find(p, TimeKind.iqamah);
    expect(got, isNotNull, reason: '$p not found');
    final diff = (got!.time.inMinutes - Hm.tryParse(want)!.inMinutes).abs();
    expect(diff, lessThanOrEqualTo(tolerance),
        reason: '$p: want $want, got ${got.time} (${got.detail})');
  }

  test('reads every prayer clock', () {
    expectTime(Prayer.fajr, '06:15');
    expectTime(Prayer.dhuhr, '13:30');
    expectTime(Prayer.asr, '17:00');
    // The hands overlap exactly (they coincide at 6:32:43), so a minute or
    // two either way is the honest precision; it must be flagged instead.
    expectTime(Prayer.maghrib, '18:33', tolerance: 2);
    expect(reading.find(Prayer.maghrib, TimeKind.iqamah)!.confidence,
        lessThan(0.8));
    expectTime(Prayer.isha, '20:15');
    expectTime(Prayer.jumuah, '13:45');
    expect(reading.missing, isEmpty);
  });

  test('reads the current-time clock and it matches the photo', () {
    expect(reading.displayClock, isNotNull);
    final diff = (reading.displayClock!.time.inMinutes - (16 * 60 + 53)).abs();
    expect(diff, lessThanOrEqualTo(1));
    expect(reading.warnings, isEmpty);
  });
}
