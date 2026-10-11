import 'package:salat_reader/salat_reader.dart';
import 'package:test/test.dart';

/// Builds OCR lines on a simple grid: each row is a list of cell texts,
/// laid out left to right.
List<OcrLine> table(List<List<String>> rows,
    {double rowHeight = 40, double colWidth = 160}) {
  final lines = <OcrLine>[];
  for (var r = 0; r < rows.length; r++) {
    for (var c = 0; c < rows[r].length; c++) {
      final text = rows[r][c];
      if (text.isEmpty) continue;
      final l = c * colWidth, t = r * rowHeight;
      lines.add(OcrLine(text, l, t, l + text.length * 12, t + 30));
    }
  }
  return lines;
}

void main() {
  final parser = TextBoardParser();
  Hm? time(BoardReading r, Prayer p, TimeKind k) => r.find(p, k)?.time;

  test('table with adhan and iqamah columns', () {
    final r = parser.parse(table([
      ['', 'Adhan', 'Iqamah'],
      ['Fajr', '5:41', '6:15'],
      ['Sunrise', '7:02', ''],
      ['Dhuhr', '12:51', '1:30'],
      ['Asr', '3:58', '5:00'],
      ['Maghrib', '6:23', '6:33'],
      ['Isha', '7:44', '8:15'],
      ["Jumu'ah", '', '1:45'],
    ]), imageWidth: 600, imageHeight: 400);
    expect(time(r, Prayer.fajr, TimeKind.adhan), const Hm(5, 41));
    expect(time(r, Prayer.fajr, TimeKind.iqamah), const Hm(6, 15));
    expect(time(r, Prayer.sunrise, TimeKind.adhan), const Hm(7, 2));
    expect(time(r, Prayer.dhuhr, TimeKind.iqamah), const Hm(13, 30));
    expect(time(r, Prayer.asr, TimeKind.adhan), const Hm(15, 58));
    expect(time(r, Prayer.maghrib, TimeKind.iqamah), const Hm(18, 33));
    expect(time(r, Prayer.isha, TimeKind.iqamah), const Hm(20, 15));
    expect(time(r, Prayer.jumuah, TimeKind.iqamah), const Hm(13, 45));
    expect(r.warnings, isEmpty);
  });

  test('single column of times is taken as iqamah, with a note', () {
    final r = parser.parse(table([
      ['FAJR', '6:15 AM'],
      ['ZUHR', '1:30 PM'],
      ['ASR', '5:00 PM'],
      ['MAGHRIB', '6:33 PM'],
      ['ISHA', '8:15 PM'],
    ]), imageWidth: 400, imageHeight: 300);
    expect(time(r, Prayer.dhuhr, TimeKind.iqamah), const Hm(13, 30));
    expect(time(r, Prayer.maghrib, TimeKind.iqamah), const Hm(18, 33));
    expect(r.warnings.single, contains('iqamah'));
  });

  test('columns layout (names across the top) and 24-hour times', () {
    final r = parser.parse(table([
      ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'],
      ['06:15', '13:30', '17:00', '18:33', '20:15'],
    ]), imageWidth: 800, imageHeight: 100);
    expect(time(r, Prayer.fajr, TimeKind.iqamah), const Hm(6, 15));
    expect(time(r, Prayer.isha, TimeKind.iqamah), const Hm(20, 15));
  });

  test('LCD look-alike characters and Arabic names', () {
    final r = parser.parse(table([
      ['الفجر', '6:I5'],
      ['الظهر', 'l:30'],
      ['العصر', 'S:00'],
      ['المغرب', '6:33'],
      ['العشاء', 'B:15'],
    ]), imageWidth: 400, imageHeight: 300);
    expect(time(r, Prayer.fajr, TimeKind.iqamah), const Hm(6, 15));
    expect(time(r, Prayer.asr, TimeKind.iqamah), const Hm(17, 0));
    expect(time(r, Prayer.isha, TimeKind.iqamah), const Hm(20, 15));
    expect(r.find(Prayer.fajr, TimeKind.iqamah)!.confidence, lessThan(0.8));
  });

  test('a big leftover time is the display clock', () {
    final lines = [
      ...table([
        ['Fajr', '6:15'],
        ['Dhuhr', '1:30'],
      ]),
      const OcrLine('4:53', 0, 200, 300, 320),
    ];
    final r = parser.parse(lines, imageWidth: 400, imageHeight: 400);
    expect(r.displayClock?.time.minute, 53);
  });
}
