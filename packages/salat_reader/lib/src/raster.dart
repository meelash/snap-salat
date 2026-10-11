import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// An upright RGB image with fast pixel access.
class Raster {
  final int width, height;

  /// Packed RGB, row major.
  final Uint8List rgb;

  Raster(this.width, this.height, this.rgb);

  factory Raster.fromImage(img.Image image) => Raster(image.width,
      image.height, image.getBytes(order: img.ChannelOrder.rgb));

  /// Decodes JPEG/PNG/etc bytes and applies the EXIF orientation so the
  /// raster is the way the photographer saw it.
  static Raster decode(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('Unsupported image');
    return Raster.fromImage(img.bakeOrientation(decoded));
  }

  /// Box-filter downscale so the longest side is at most [maxSide].
  Raster downscaled(int maxSide) {
    final scale = math.max(width, height) / maxSide;
    if (scale <= 1) return this;
    final w = (width / scale).round(), h = (height / scale).round();
    final out = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      final y0 = (y * scale).floor(), y1 = math.min(height, ((y + 1) * scale).ceil());
      for (var x = 0; x < w; x++) {
        final x0 = (x * scale).floor(), x1 = math.min(width, ((x + 1) * scale).ceil());
        var r = 0, g = 0, b = 0, n = 0;
        for (var sy = y0; sy < y1; sy++) {
          var i = (sy * width + x0) * 3;
          for (var sx = x0; sx < x1; sx++, i += 3) {
            r += rgb[i];
            g += rgb[i + 1];
            b += rgb[i + 2];
            n++;
          }
        }
        final o = (y * w + x) * 3;
        out[o] = r ~/ n;
        out[o + 1] = g ~/ n;
        out[o + 2] = b ~/ n;
      }
    }
    return Raster(w, h, out);
  }

  /// Perceived brightness 0..255 of every pixel.
  Uint8List luminance() {
    final out = Uint8List(width * height);
    for (var p = 0, i = 0; p < out.length; p++, i += 3) {
      out[p] = (rgb[i] * 299 + rgb[i + 1] * 587 + rgb[i + 2] * 114) ~/ 1000;
    }
    return out;
  }

  /// Chroma (max - min channel) 0..255 of every pixel; 0 is grey.
  Uint8List chroma() {
    final out = Uint8List(width * height);
    for (var p = 0, i = 0; p < out.length; p++, i += 3) {
      final r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
      out[p] = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
    }
    return out;
  }

  /// Bilinear sample at (x, y); writes luminance and chroma into [out].
  void sample(double x, double y, Float64List out) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > width - 1.001) x = width - 1.001;
    if (y > height - 1.001) y = height - 1.001;
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    var r = 0.0, g = 0.0, b = 0.0;
    for (var k = 0; k < 4; k++) {
      final dx = k & 1, dy = k >> 1;
      final w = (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy);
      final i = ((y0 + dy) * width + x0 + dx) * 3;
      r += rgb[i] * w;
      g += rgb[i + 1] * w;
      b += rgb[i + 2] * w;
    }
    out[0] = r * 0.299 + g * 0.587 + b * 0.114;
    out[1] = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  }
}

/// When and how the photo's capture time was determined.
class CaptureTime {
  /// Local wall-clock time on the camera.
  final DateTime local;

  /// UTC offset recorded by the camera, if it recorded one.
  final Duration? offset;

  const CaptureTime(this.local, this.offset);

  /// ISO 8601 with offset when known, e.g. `2026-10-09T16:53:38-04:00`.
  String toIso8601() {
    String two(int n) => n.toString().padLeft(2, '0');
    final l = local;
    final base = '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}'
        'T${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
    final o = offset;
    if (o == null) return base;
    final sign = o.isNegative ? '-' : '+';
    final abs = o.abs();
    return '$base$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
  }

  /// Reads DateTimeOriginal (and OffsetTimeOriginal) from JPEG EXIF.
  static CaptureTime? fromExif(Uint8List jpeg) {
    final exif = img.decodeJpgExif(jpeg);
    if (exif == null) return null;
    final dt = (exif.exifIfd['DateTimeOriginal'] ?? exif.imageIfd['DateTime'])
        ?.toString()
        .replaceAll('\x00', '')
        .trim();
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})')
        .firstMatch(dt ?? '');
    if (m == null) return null;
    final local = DateTime(int.parse(m[1]!), int.parse(m[2]!),
        int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
    final off = (exif.exifIfd['OffsetTimeOriginal'] ?? exif.exifIfd['OffsetTime'])
        ?.toString()
        .replaceAll('\x00', '')
        .trim();
    final om = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(off ?? '');
    Duration? offset;
    if (om != null) {
      offset = Duration(hours: int.parse(om[2]!), minutes: int.parse(om[3]!));
      if (om[1] == '-') offset = -offset;
    }
    return CaptureTime(local, offset);
  }
}
