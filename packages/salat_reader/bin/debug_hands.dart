import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:salat_reader/src/analog/face_detector.dart';
import 'package:salat_reader/src/analog/hand_reader.dart';
import 'package:salat_reader/src/raster.dart';

/// Development aid: writes one crop per clock with the dark mask (red) and
/// chosen hands (blue = hour, green = minute).
/// Usage: dart run bin/debug_hands.dart photo.jpg outdir
void main(List<String> args) {
  final raster = Raster.decode(File(args[0]).readAsBytesSync());
  final faces = FaceDetector().detect(raster);
  final full = img.Image.fromBytes(
      width: raster.width, height: raster.height, bytes: raster.rgb.buffer, numChannels: 3);
  var i = 0;
  for (final f in faces) {
    final r = HandReader().read(raster, f);
    final rad = f.radius;
    final x0 = (f.cx - rad * 1.1).round(), y0 = (f.cy - rad * 1.1).round();
    final crop = img.copyCrop(full, x: x0, y: y0, width: (rad * 2.2).round(), height: (rad * 2.2).round());
    for (final (x, y) in debugDarkPoints(raster, f)) {
      crop.setPixelRgb(x.round() - x0, y.round() - y0, 255, 0, 0);
    }
    void hand(HandCandidate? h, img.Color c) {
      if (h == null) return;
      final (ax, ay) = r!.face.at(0, h.angle);
      final (bx, by) = r.face.at(h.length, h.angle);
      img.drawLine(crop, x1: ax.round() - x0, y1: ay.round() - y0, x2: bx.round() - x0, y2: by.round() - y0, color: c, thickness: 3);
    }
    hand(r?.best.hourHand, img.ColorRgb8(0, 0, 255));
    hand(r?.best.minuteHand, img.ColorRgb8(0, 200, 0));
    File('${args[1]}/clock${i++}.jpg').writeAsBytesSync(img.encodeJpg(img.copyResize(crop, width: 300)));
    print('clock${i - 1}: $r');
  }
}
