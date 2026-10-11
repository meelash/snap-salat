import 'package:salat_reader/salat_reader.dart';
import 'package:salat_reader/src/labeling.dart';
import 'package:test/test.dart';

void main() {
  group('to24h', () {
    test('picks AM or PM from the prayer', () {
      expect(to24h(Prayer.fajr, 6 * 60 + 15), 6 * 60 + 15);
      expect(to24h(Prayer.dhuhr, 1 * 60 + 30), 13 * 60 + 30);
      expect(to24h(Prayer.dhuhr, 0 * 60 + 15), 12 * 60 + 15); // 12:15
      expect(to24h(Prayer.asr, 5 * 60), 17 * 60);
      expect(to24h(Prayer.isha, 8 * 60 + 15), 20 * 60 + 15);
    });

    test('isha can be after midnight', () {
      expect(to24h(Prayer.isha, 0 * 60 + 30), 24 * 60 + 30);
    });
  });

  group('labelSlots', () {
    // Six clocks in a 2x3 grid; times listed in RTL row order.
    List<Slot> grid(List<int> rtlMinutes12) {
      final pos = [(2.0, 0.0), (1.0, 0.0), (2.0, 1.0), (1.0, 1.0), (2.0, 2.0), (1.0, 2.0)];
      return [
        for (var i = 0; i < 6; i++)
          Slot(pos[i].$1 * 100, pos[i].$2 * 100, 40, rtlMinutes12[i])
      ];
    }

    test('finds the right-to-left row order from the times alone', () {
      final slots = grid([375, 90, 300, 393, 495, 105]);
      final l = labelSlots(slots);
      expect(l.labels, [
        Prayer.fajr, Prayer.dhuhr, Prayer.asr,
        Prayer.maghrib, Prayer.isha, Prayer.jumuah,
      ]);
      expect(l.order, ReadingOrder.rtlRows);
      expect(l.confident, isTrue);
    });

    test('an unreadable clock keeps its place', () {
      final slots = grid([375, 90, 300, 393, 495, 105]);
      slots[2] = Slot(slots[2].x, slots[2].y, slots[2].size, null);
      final l = labelSlots(slots);
      expect(l.labels[2], Prayer.asr);
      expect(l.labels[5], Prayer.jumuah);
    });

    test('an explicit layout wins', () {
      final slots = grid([375, 90, 300, 393, 495, 105]);
      final l = labelSlots(slots,
          order: ReadingOrder.ltrRows,
          sequence: [Prayer.dhuhr, Prayer.fajr, Prayer.maghrib, Prayer.asr, Prayer.jumuah, Prayer.isha]);
      expect(l.labels[0], Prayer.fajr);
      expect(l.labels[1], Prayer.dhuhr);
      expect(l.confident, isTrue);
    });
  });

  group('Hm', () {
    test('formats and parses the wire format', () {
      expect(const Hm(6, 5).toString(), '06:05');
      expect(Hm.tryParse('18:33'), const Hm(18, 33));
      expect(Hm.tryParse('24:00'), isNull);
      expect(const Hm(13, 5).to12h(), '1:05 PM');
    });
  });
}
