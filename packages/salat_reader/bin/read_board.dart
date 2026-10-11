import 'dart:convert';
import 'dart:io';

import 'package:salat_reader/salat_reader.dart';

/// Reads a photo of an analog prayer-time board and prints JSON.
///
///   dart run bin/read_board.dart photo.jpg [--debug]
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: read_board <photo> [--debug]');
    exit(64);
  }
  final bytes = File(args.first).readAsBytesSync();
  final debug = args.contains('--debug') ? <String>[] : null;
  final sw = Stopwatch()..start();
  final reading = readAnalogBoard(bytes, debug: debug);
  debug?.forEach(stderr.writeln);
  stderr.writeln('read in ${sw.elapsedMilliseconds} ms');
  final captured = CaptureTime.fromExif(bytes);
  print(const JsonEncoder.withIndent('  ').convert({
    if (captured != null) 'captured_at': captured.toIso8601(),
    ...reading.toJson(),
  }));
}
