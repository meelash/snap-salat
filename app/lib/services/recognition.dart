import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:salat_reader/salat_reader.dart';

import '../models/masjid.dart';

/// Which reader to use on a photo.
enum ReaderChoice {
  auto('Auto'),
  analog('Clocks'),
  text('Text / digital');

  final String label;
  const ReaderChoice(this.label);
}

/// A photo picked or taken by the user.
class PhotoInput {
  final Uint8List bytes;
  final String path;

  /// True if taken with the camera just now inside the app.
  final bool fromCamera;
  final DateTime? fileModified;

  const PhotoInput(this.bytes, this.path,
      {required this.fromCamera, this.fileModified});
}

/// When the photo was taken, and how we know.
class CaptureInfo {
  final DateTime local;
  final Duration offset;

  /// `exif`, `camera` or `file` (see docs/api.md). Never user-editable.
  final String source;

  const CaptureInfo(this.local, this.offset, this.source);

  String get iso {
    String two(int n) => n.toString().padLeft(2, '0');
    final sign = offset.isNegative ? '-' : '+';
    final o = offset.abs();
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
        '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
        '${two(local.second)}$sign${two(o.inHours)}:${two(o.inMinutes % 60)}';
  }

  String get date =>
      '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';

  Duration get age => DateTime.now().difference(local);
}

class RecognitionResult {
  final BoardReading reading;
  final CaptureInfo capture;
  final String imageSha256;

  const RecognitionResult(this.reading, this.capture, this.imageSha256);
}

/// Works out the capture time: EXIF if the camera recorded it, otherwise
/// "now" for photos just taken, otherwise the file's timestamp.
CaptureInfo captureInfoFor(PhotoInput photo) {
  final exif = CaptureTime.fromExif(photo.bytes);
  if (exif != null) {
    final local = exif.local;
    return CaptureInfo(local, exif.offset ?? local.timeZoneOffset,
        photo.fromCamera ? 'camera' : 'exif');
  }
  final t = photo.fromCamera
      ? DateTime.now()
      : (photo.fileModified ?? DateTime.now());
  return CaptureInfo(t, t.timeZoneOffset, photo.fromCamera ? 'camera' : 'file');
}

/// Reads a photo with the reader that suits it.
Future<RecognitionResult> recognise(PhotoInput photo,
    {DisplayHints? hints, ReaderChoice choice = ReaderChoice.auto}) async {
  final capture = captureInfoFor(photo);
  final sha = sha256.convert(photo.bytes).toString();

  var effective = choice;
  if (choice == ReaderChoice.auto) {
    effective = switch (hints?.type) {
      'analog-clocks' => ReaderChoice.analog,
      'text' => ReaderChoice.text,
      _ => ReaderChoice.auto,
    };
  }

  BoardReading? analog;
  if (effective != ReaderChoice.text) {
    final a = await compute(
        _readAnalog,
        _AnalogJob(
            photo.bytes, hints?.toJson(), capture.local.toIso8601String()));
    if (effective == ReaderChoice.analog || _labelled(a) >= 4) {
      return RecognitionResult(a, capture, sha);
    }
    analog = a;
  }
  final text = await _readText(photo);
  final best =
      analog == null || _labelled(text) > _labelled(analog) ? text : analog;
  return RecognitionResult(best, capture, sha);
}

int _labelled(BoardReading r) => r.times.where((t) => t.prayer != null).length;

class _AnalogJob {
  final Uint8List bytes;
  final Map<String, Object?>? hints;
  final String capturedLocal;
  _AnalogJob(this.bytes, this.hints, this.capturedLocal);
}

BoardReading _readAnalog(_AnalogJob job) {
  final hints = job.hints == null ? null : DisplayHints.fromJson(job.hints!);
  final local = DateTime.parse(job.capturedLocal);
  return readAnalogBoard(job.bytes,
      layout: hints?.analogLayout, captured: CaptureTime(local, null));
}

/// On-device OCR (ML Kit, Latin script) fed to the text-board parser.
Future<BoardReading> _readText(PhotoInput photo) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final text =
        await recognizer.processImage(InputImage.fromFilePath(photo.path));
    final lines = <OcrLine>[
      for (final block in text.blocks)
        for (final line in block.lines)
          OcrLine(
            line.text,
            line.boundingBox.left,
            line.boundingBox.top,
            line.boundingBox.right,
            line.boundingBox.bottom,
            [
              for (final e in line.elements)
                OcrWord(e.text, e.boundingBox.left, e.boundingBox.top,
                    e.boundingBox.right, e.boundingBox.bottom)
            ],
          )
    ];
    final size = await _uprightSize(photo.bytes);
    return TextBoardParser()
        .parse(lines, imageWidth: size.$1, imageHeight: size.$2);
  } finally {
    await recognizer.close();
  }
}

/// Image size as displayed (Flutter's decoder applies EXIF orientation).
Future<(int, int)> _uprightSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final size = (frame.image.width, frame.image.height);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  return size;
}

/// A smaller JPEG of the photo for servers that want it.
Future<String> photoForUpload(Uint8List bytes) => compute(_shrink, bytes);

String _shrink(Uint8List bytes) {
  final decoded = img.bakeOrientation(img.decodeImage(bytes)!);
  final longest =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  final scaled = longest <= 1600
      ? decoded
      : img.copyResize(decoded,
          width: decoded.width >= decoded.height ? 1600 : null,
          height: decoded.height > decoded.width ? 1600 : null,
          interpolation: img.Interpolation.average);
  return base64Encode(img.encodeJpg(scaled, quality: 80));
}
