import 'dart:math' as math;

import 'package:salat_reader/salat_reader.dart';
import 'package:test/test.dart';

import 'support/synthetic_board.dart';

/// Randomised boards (hand styles, shadows, glare, roll, perspective,
/// noise). Guards against overfitting the one real photo.
void main() {
  test('synthetic boards: accurate, and unsure readings are flagged', () {
    final rng = math.Random(42);
    const prayers = [
      Prayer.fajr, Prayer.dhuhr, Prayer.asr,
      Prayer.maghrib, Prayer.isha, Prayer.jumuah,
    ];
    var correct = 0, total = 0, silentErrors = 0;
    for (var b = 0; b < 12; b++) {
      final times = randomPrayerTimes(rng);
      final board = renderBoard(rng, times, rng.nextInt(1440));
      final reading = AnalogBoardReader().read(Raster.fromImage(board.image));
      for (var i = 0; i < prayers.length; i++) {
        total++;
        final got = reading.find(prayers[i], TimeKind.iqamah);
        if (got == null) continue; // reported as missing instead
        if ((got.time.inMinutes - times[i]).abs() <= 1) {
          correct++;
        } else if (got.confidence >= 0.8) {
          silentErrors++;
        }
      }
    }
    expect(correct / total, greaterThanOrEqualTo(0.9));
    expect(silentErrors, lessThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
