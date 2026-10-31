import 'dart:io';

import 'package:salat_reader/salat_reader.dart';
import 'package:test/test.dart';

/// The same board as analog_sample_test.dart, photographed from below in
/// daylight (issue #1). The bezel's depth puts the big clock's outline well
/// off its hands' pivot, its hands are hollow, and Isha's minute hand
/// sits beside the 1 of 12.
void main() {
  late BoardReading reading;

  setUpAll(() {
    final bytes =
        File('../../sample_images/board-2026-10-30-glare.jpg').readAsBytesSync();
    // Re-encoded without EXIF; the photo was taken at 3:02 PM.
    reading = readAnalogBoard(bytes,
        captured: CaptureTime(DateTime(2026, 10, 30, 15, 2), null));
  });

  void expectTime(Prayer p, String want) {
    final got = reading.find(p, TimeKind.iqamah);
    expect(got, isNotNull, reason: '$p not found');
    final diff = (got!.time.inMinutes - Hm.tryParse(want)!.inMinutes).abs();
    expect(diff, lessThanOrEqualTo(1),
        reason: '$p: want $want, got ${got.time} (${got.detail})');
  }

  test('reads every prayer clock', () {
    expectTime(Prayer.fajr, '06:15');
    expectTime(Prayer.dhuhr, '13:30');
    expectTime(Prayer.asr, '16:30');
    expectTime(Prayer.maghrib, '18:01');
    expectTime(Prayer.jumuah, '12:15');
    expect(reading.missing, isEmpty);
  });

  test('reads Isha at 8:00, not 7:59, despite the 1 of 12 beside its hand', () {
    expect(reading.find(Prayer.isha, TimeKind.iqamah)!.time.toString(), '20:00');
  });

  test('reads the hollow hands of the current-time clock', () {
    final clock = reading.displayClock;
    expect(clock, isNotNull);
    expect((clock!.time.inMinutes - (15 * 60 + 2)).abs(), lessThanOrEqualTo(1),
        reason: clock.detail);
    expect(reading.warnings, isEmpty);
  });
}
