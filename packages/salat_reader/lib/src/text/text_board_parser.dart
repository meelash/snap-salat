import 'dart:math' as math;

import '../labeling.dart';
import '../models.dart';

/// A word recognised by OCR, with its box in image pixels.
class OcrWord {
  final String text;
  final double left, top, right, bottom;

  const OcrWord(this.text, this.left, this.top, this.right, this.bottom);
}

/// A line recognised by OCR. [words] may be empty if the OCR engine only
/// reports lines; positions are then interpolated across the line box.
class OcrLine {
  final String text;
  final double left, top, right, bottom;
  final List<OcrWord> words;

  const OcrLine(this.text, this.left, this.top, this.right, this.bottom,
      [this.words = const []]);
}

enum _Header { adhan, iqamah }

class _Item {
  final double left, top, right, bottom;
  _Item(this.left, this.top, this.right, this.bottom);
  double get cx => (left + right) / 2;
  double get cy => (top + bottom) / 2;
  double get w => right - left;
  double get h => bottom - top;
  Region get region => Region(left, top, w, h);
}

class _Label extends _Item {
  final Prayer prayer;
  _Label(this.prayer, super.l, super.t, super.r, super.b);
}

class _Time extends _Item {
  /// Minutes after midnight if the display said AM/PM or used 24-hour
  /// time; otherwise minutes past 12 on a 12-hour dial.
  final int minutes;
  final bool absolute;
  final String raw;
  final bool cleaned; // OCR look-alikes (O→0 etc.) were substituted
  bool used = false;
  _Time(this.minutes, this.absolute, this.raw, this.cleaned, super.l, super.t,
      super.r, super.b);
}

class _HeaderItem extends _Item {
  final _Header kind;
  _HeaderItem(this.kind, super.l, super.t, super.r, super.b);
}

/// Turns OCR output of a written, printed, LCD or screen display into
/// prayer times.
///
/// It finds prayer names (English transliterations and Arabic), times
/// (`5:45`, `5.45`, `05:45 AM`, `17:45`), and column/row headers such as
/// "Adhan/Begins" and "Iqamah/Jamaat", then pairs each name with the times
/// on its row (or below it, for boards laid out in columns).
class TextBoardParser {
  static const id = 'text';

  static final _labels = <Prayer, List<String>>{
    Prayer.fajr: ['fajr', 'fajar', 'fajir', 'fadjr', 'fajer', 'subh', 'sobh', 'فجر', 'الفجر'],
    Prayer.sunrise: ['sunrise', 'shuruq', 'shurooq', 'shorouk', 'shuruk', 'sunrise', 'شروق', 'الشروق'],
    Prayer.dhuhr: ['dhuhr', 'zuhr', 'zohr', 'zuhar', 'zohar', 'duhr', 'thuhr', 'dhuhur', 'dhur', 'zuhur', 'dhohr', 'ظهر', 'الظهر'],
    Prayer.asr: ['asr', 'asar', 'aser', 'عصر', 'العصر'],
    Prayer.maghrib: ['maghrib', 'magrib', 'maghreb', 'mughrib', 'magrib', 'مغرب', 'المغرب'],
    Prayer.isha: ['isha', 'ishaa', 'esha', 'eshaa', 'ishā', 'ishah', 'عشاء', 'العشاء'],
    Prayer.jumuah: ['jumuah', 'jumua', 'jummah', 'jumma', 'juma', 'jumah', 'jumaa', 'jumu', 'friday', 'جمعة', 'الجمعة'],
  };

  static final _headers = <_Header, List<String>>{
    _Header.adhan: ['adhan', 'adhaan', 'azan', 'azaan', 'athan', 'athaan', 'begins', 'begin', 'beginning', 'start', 'starts', 'starting', 'أذان', 'الأذان', 'اذان'],
    _Header.iqamah: ['iqamah', 'iqama', 'iqamat', 'iqaamah', 'ikamah', 'jamaat', 'jamat', 'jamaah', 'jamah', 'congregation', 'إقامة', 'الإقامة', 'اقامة', 'جماعة'],
  };

  // Digits plus letters OCR often confuses with them on LCD/segment fonts.
  static const _d = r'[0-9OoIlSB]';
  static final _timePattern = RegExp(
      '(?<![0-9])($_d{1,2})\\s?[:.·]\\s?($_d{2})(?![0-9])\\s*([aApP]\\.?\\s?[mM]\\.?)?');

  BoardReading parse(List<OcrLine> lines,
      {required int imageWidth, required int imageHeight}) {
    final labels = <_Label>[];
    final times = <_Time>[];
    final headers = <_HeaderItem>[];
    for (final line in lines) {
      final words = line.words.isNotEmpty ? line.words : _splitLine(line);
      _scanWords(words, labels, headers);
      _scanTimes(line, words, times);
    }
    // The same prayer can be named twice (English and Arabic); keep both,
    // they'll find the same times, and duplicates are dropped below.

    final warnings = <String>[];
    final out = <TimeReading>[];
    if (labels.isEmpty) {
      warnings.add('No prayer names found on the display.');
    }

    // Labels stacked vertically → each row holds a prayer's times.
    final rowsLayout = labels.length < 2 ||
        _spread(labels.map((l) => l.cy)) >= _spread(labels.map((l) => l.cx));

    for (final label in labels) {
      final mine = times.where((t) {
        if (rowsLayout) {
          final tol = 0.6 * math.max(label.h, t.h);
          return (t.cy - label.cy).abs() < tol;
        }
        final tol = 0.6 * math.max(label.w, t.w);
        return (t.cx - label.cx).abs() < tol && t.cy > label.cy;
      }).toList()
        ..sort((a, b) => rowsLayout ? a.cx.compareTo(b.cx) : a.cy.compareTo(b.cy));
      if (mine.isEmpty) continue;

      List<_Header?> kinds;
      if (headers.isNotEmpty) {
        kinds = [
          for (final t in mine)
            _nearest(headers, (h) => rowsLayout ? (h.cx - t.cx).abs() : (h.cy - t.cy).abs())
                ?.kind
        ];
      } else if (label.prayer == Prayer.jumuah) {
        kinds = List.filled(mine.length, _Header.iqamah);
      } else if (mine.length >= 2) {
        // Without headers, the usual convention is begins/adhan first.
        kinds = [_Header.adhan, _Header.iqamah, ...List.filled(mine.length - 2, null)];
      } else {
        kinds = [_Header.iqamah];
      }

      for (var i = 0; i < mine.length; i++) {
        final kindH = kinds[i];
        if (kindH == null) continue;
        final t = mine[i];
        final kind = label.prayer == Prayer.sunrise
            ? TimeKind.adhan
            : (kindH == _Header.adhan ? TimeKind.adhan : TimeKind.iqamah);
        final minutes = t.absolute ? t.minutes : to24h(label.prayer, t.minutes);
        final dup = out.any((o) =>
            o.prayer == label.prayer &&
            o.kind == kind &&
            o.time.inMinutes == minutes % 1440);
        if (dup) continue;
        // One time per prayer and kind (a single Jumu'ah included).
        if (out.any((o) => o.prayer == label.prayer && o.kind == kind)) {
          continue;
        }
        t.used = true;
        out.add(TimeReading(
          prayer: label.prayer,
          kind: kind,
          time: Hm.fromMinutes(minutes),
          confidence: t.cleaned ? 0.6 : 0.85,
          region: t.region,
          detail: 'OCR "${t.raw}"',
        ));
      }
    }
    if (headers.isEmpty &&
        out.any((t) => t.kind == TimeKind.iqamah && t.prayer != Prayer.jumuah) &&
        !out.any((t) => t.kind == TimeKind.adhan && t.prayer != Prayer.sunrise)) {
      warnings.add('Assumed these are congregation (iqamah) times. '
          'Switch them to adhan if the board shows when prayer begins.');
    }

    // A large leftover time is probably the display's current-time clock.
    TimeReading? displayClock;
    final leftovers = times.where((t) => !t.used).toList();
    if (leftovers.isNotEmpty && times.length > leftovers.length) {
      final usedHeights = [for (final t in times.where((t) => t.used)) t.h]..sort();
      final median = usedHeights[usedHeights.length ~/ 2];
      leftovers.sort((a, b) => b.h.compareTo(a.h));
      final big = leftovers.first;
      if (big.h > 1.5 * median) {
        displayClock = TimeReading(
          prayer: null,
          kind: TimeKind.adhan,
          time: Hm.fromMinutes(big.minutes),
          confidence: 0.7,
          region: big.region,
          detail: 'OCR "${big.raw}"',
        );
      }
    }

    out.sort((a, b) {
      final c = a.prayer!.index.compareTo(b.prayer!.index);
      return c != 0 ? c : a.kind.index.compareTo(b.kind.index);
    });
    _checkOrder(out, warnings);
    return BoardReading(
      reader: id,
      times: out,
      displayClock: displayClock,
      warnings: warnings,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }

  static void _checkOrder(List<TimeReading> out, List<String> warnings) {
    for (final kind in TimeKind.values) {
      final assigned = [
        for (final t in out)
          if (t.kind == kind && t.prayer != Prayer.jumuah)
            (t.prayer!, t.time.inMinutes < 180 && t.prayer == Prayer.isha
                ? t.time.inMinutes + 1440
                : t.time.inMinutes)
      ];
      if (sequencePenalty(assigned) >= 1) {
        warnings.add('Some ${kind.name} times look out of order. '
            'Please double-check them.');
        for (final t in out.where((t) => t.kind == kind)) {
          t.confidence = math.min(t.confidence, 0.5);
        }
      }
    }
  }

  void _scanWords(
      List<OcrWord> words, List<_Label> labels, List<_HeaderItem> headers) {
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final norm = _normalise(w.text);
      if (norm.isEmpty) continue;
      // "Sun rise" / "Jumu ah" split over two words.
      final next = i + 1 < words.length ? _normalise(words[i + 1].text) : '';
      for (final MapEntry(key: prayer, value: names) in _labels.entries) {
        if (names.contains(norm) || names.contains(norm + next)) {
          labels.add(_Label(prayer, w.left, w.top, w.right, w.bottom));
        }
      }
      for (final MapEntry(key: kind, value: names) in _headers.entries) {
        if (names.contains(norm)) {
          headers.add(_HeaderItem(kind, w.left, w.top, w.right, w.bottom));
        }
      }
    }
  }

  void _scanTimes(OcrLine line, List<OcrWord> words, List<_Time> out) {
    // Rebuild the line from words so character offsets map to boxes.
    final buf = StringBuffer();
    final spans = <(int, int, OcrWord)>[];
    for (final w in words) {
      if (buf.isNotEmpty) buf.write(' ');
      final start = buf.length;
      buf.write(w.text);
      spans.add((start, buf.length, w));
    }
    final text = buf.toString();
    for (final m in _timePattern.allMatches(text)) {
      final rawH = m[1]!, rawM = m[2]!;
      final h = int.tryParse(_digits(rawH)), min = int.tryParse(_digits(rawM));
      if (h == null || min == null || h > 23 || min > 59) continue;
      final cleaned = _digits(rawH) != rawH || _digits(rawM) != rawM;
      // Don't read dates (12.10) or numbers inside words as times.
      if (cleaned && !RegExp(r'[0-9]').hasMatch(rawH + rawM)) continue;
      final ampm = m[3]?.toLowerCase().replaceAll(RegExp(r'[^ap]'), '');
      int minutes;
      bool absolute;
      if (ampm == 'a' || ampm == 'p') {
        if (h == 0 || h > 12) continue;
        minutes = (h % 12) * 60 + min + (ampm == 'p' ? 720 : 0);
        absolute = true;
      } else if (h >= 13 || h == 0) {
        minutes = h * 60 + min;
        absolute = true;
      } else {
        minutes = (h % 12) * 60 + min;
        absolute = false;
      }
      double l = double.infinity, t = double.infinity, r = -1, b = -1;
      for (final (s, e, w) in spans) {
        if (e <= m.start || s >= m.end) continue;
        l = math.min(l, w.left);
        t = math.min(t, w.top);
        r = math.max(r, w.right);
        b = math.max(b, w.bottom);
      }
      if (r < 0) continue;
      out.add(_Time(minutes, absolute, m[0]!.trim(), cleaned, l, t, r, b));
    }
  }

  /// Words with boxes interpolated by character position.
  static List<OcrWord> _splitLine(OcrLine line) {
    final total = line.text.length;
    if (total == 0) return const [];
    final out = <OcrWord>[];
    final width = line.right - line.left;
    for (final m in RegExp(r'\S+').allMatches(line.text)) {
      out.add(OcrWord(
        m[0]!,
        line.left + width * m.start / total,
        line.top,
        line.left + width * m.end / total,
        line.bottom,
      ));
    }
    return out;
  }

  static String _normalise(String s) => s
      .toLowerCase()
      .replaceAll(RegExp("[’'`ʼ\\-_.:,;()]"), '')
      .replaceAll(RegExp(r'[ً-ْٰ]'), '') // Arabic diacritics
      .trim();

  static String _digits(String s) => s
      .replaceAll(RegExp('[Oo]'), '0')
      .replaceAll(RegExp('[Il]'), '1')
      .replaceAll('S', '5')
      .replaceAll('B', '8');

  static double _spread(Iterable<double> v) {
    if (v.isEmpty) return 0;
    return v.reduce(math.max) - v.reduce(math.min);
  }

  static T? _nearest<T>(List<T> items, double Function(T) distance) {
    T? best;
    var bestD = double.infinity;
    for (final i in items) {
      final d = distance(i);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }
}
