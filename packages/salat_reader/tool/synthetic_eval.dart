import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:salat_reader/salat_reader.dart';

import '../test/support/synthetic_board.dart';

/// Reads [count] random synthetic boards and reports accuracy.
///   dart run tool/synthetic_eval.dart [count] [seed] [dump-dir]
void main(List<String> args) {
  final count = args.isNotEmpty ? int.parse(args[0]) : 20;
  final rng = math.Random(args.length > 1 ? int.parse(args[1]) : 1);
  final dump = args.length > 2 ? args[2] : null;
  const prayers = [Prayer.fajr, Prayer.dhuhr, Prayer.asr, Prayer.maghrib, Prayer.isha, Prayer.jumuah];
  var ok = 0, total = 0, clockOk = 0, silent = 0, flagged = 0;
  for (var b = 0; b < count; b++) {
    final times = randomPrayerTimes(rng);
    final current = rng.nextInt(1440);
    final board = renderBoard(rng, times, current);
    final reading = AnalogBoardReader().read(Raster.fromImage(board.image));
    final errors = <String>[];
    for (var i = 0; i < 6; i++) {
      total++;
      final got = reading.find(prayers[i], TimeKind.iqamah);
      final want = Hm.fromMinutes(times[i]);
      final diff = got == null ? 999 : (got.time.inMinutes - want.inMinutes).abs();
      if (got != null && got.confidence < 0.8) flagged++;
      if (diff <= 1) {
        ok++;
      } else {
        if (got != null && got.confidence >= 0.8) silent++;
        errors.add('${prayers[i].name} want $want got ${got?.time} (${got?.detail})');
      }
    }
    final dc = reading.displayClock;
    if (dc != null && ((dc.time.inMinutes % 720) - board.currentMinutes12).abs() <= 1) clockOk++;
    stdout.writeln('board $b: ${errors.isEmpty ? 'ok' : errors.join('; ')}'
        '${reading.warnings.isEmpty ? '' : ' [${reading.warnings.join(' ')}]'}');
    if (dump != null && errors.isNotEmpty) {
      File('$dump/synthetic_$b.jpg').writeAsBytesSync(img.encodeJpg(board.image));
    }
  }
  stdout.writeln('prayer clocks within 1 min: $ok/$total; current clock: $clockOk/$count; '
      'flagged for review: $flagged; wrong but confident: $silent');
}
