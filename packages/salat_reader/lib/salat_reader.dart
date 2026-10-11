/// Reads masjid prayer-time displays from photos.
///
/// Pure Dart (no Flutter), so it runs in an isolate on the phone and in
/// plain `dart test` on a laptop.
library salat_reader;

import 'dart:typed_data';

import 'src/analog/analog_board_reader.dart';
import 'src/models.dart';
import 'src/raster.dart';

export 'src/analog/analog_board_reader.dart' show AnalogBoardReader, AnalogLayout;
export 'src/labeling.dart' show ReadingOrder, to24h;
export 'src/models.dart';
export 'src/raster.dart' show CaptureTime, Raster;
export 'src/text/text_board_parser.dart';

/// Decodes [imageBytes] and reads it as an analog clock board.
///
/// The capture time from EXIF (if present) is used to check the board's
/// current-time clock.
BoardReading readAnalogBoard(Uint8List imageBytes,
    {AnalogLayout? layout, CaptureTime? captured, List<String>? debug}) {
  final raster = Raster.decode(imageBytes);
  return AnalogBoardReader().read(raster,
      captured: captured ?? CaptureTime.fromExif(imageBytes),
      layout: layout,
      debug: debug);
}
