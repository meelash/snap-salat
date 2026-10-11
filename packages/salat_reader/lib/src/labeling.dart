import 'models.dart';

/// Converts a 12-hour reading (minutes past 12:00, 0..719) into minutes
/// after midnight for [prayer], picking AM or PM by the prayer's plausible
/// window. Isha after midnight comes back as ≥ 1440.
int to24h(Prayer prayer, int minutes12) {
  final (lo, hi) = prayer.window;
  final options = [minutes12, minutes12 + 720, minutes12 + 1440];
  var best = options.first;
  var bestDist = 1 << 30;
  for (final m in options) {
    final dist = m < lo ? lo - m : (m > hi ? m - hi : 0);
    if (dist < bestDist) {
      bestDist = dist;
      best = m;
    }
  }
  return best;
}

/// How implausible [minutes] (after midnight, possibly ≥ 1440 for Isha) is
/// for [prayer]: 0 inside its window, growing by 1 per hour outside.
double windowPenalty(Prayer prayer, int minutes) {
  final (lo, hi) = prayer.window;
  if (minutes < lo) return (lo - minutes) / 60;
  if (minutes > hi) return (minutes - hi) / 60;
  return 0;
}

/// Penalty for a full assignment: each time outside its window, plus each
/// pair out of the order the day runs in.
double sequencePenalty(List<(Prayer, int)> assigned) {
  var p = 0.0;
  for (final (prayer, m) in assigned) {
    p += windowPenalty(prayer, m);
  }
  const order = [
    Prayer.fajr,
    Prayer.sunrise,
    Prayer.dhuhr,
    Prayer.asr,
    Prayer.maghrib,
    Prayer.isha
  ];
  final daily = [
    for (final a in assigned)
      if (order.contains(a.$1)) a
  ]..sort((a, b) => order.indexOf(a.$1).compareTo(order.indexOf(b.$1)));
  for (var i = 1; i < daily.length; i++) {
    if (daily[i].$2 <= daily[i - 1].$2) p += 3;
  }
  return p;
}

/// A clock (or time) at a position on the board, to be labelled.
class Slot {
  final double x, y, size;

  /// Minutes past 12:00 (0..719) as shown on a 12-hour dial, or null if
  /// it couldn't be read (the slot still counts for the layout).
  final int? minutes12;

  const Slot(this.x, this.y, this.size, this.minutes12);
}

/// Reading orders a board might use.
enum ReadingOrder {
  /// Rows top to bottom, each right to left (common on Arabic/Urdu boards).
  rtlRows,
  ltrRows,

  /// Columns right to left, each top to bottom.
  rtlColumns,
  ltrColumns;

  static ReadingOrder? parse(String? s) => switch (s) {
        'rtl-rows' => rtlRows,
        'ltr-rows' => ltrRows,
        'rtl-columns' => rtlColumns,
        'ltr-columns' => ltrColumns,
        _ => null,
      };
}

/// Result of labelling slots.
class Labelling {
  /// Prayer for each slot (same order as the input), null if unknown.
  final List<Prayer?> labels;

  /// Whether the winning layout clearly beat every alternative.
  final bool confident;
  final ReadingOrder? order;

  const Labelling(this.labels, this.confident, this.order);
}

/// Works out which slot is which prayer.
///
/// Boards rarely label clocks in a machine-readable way, but prayers happen
/// in a fixed order at roughly known times. So we try natural reading
/// orders and label sequences and keep the one whose times make the most
/// sense (each prayer in its window, the day in order). An explicit order
/// and sequence (e.g. from the masjid's registry entry) skip the guessing.
Labelling labelSlots(List<Slot> slots,
    {ReadingOrder? order, List<Prayer>? sequence}) {
  final n = slots.length;
  final templates = sequence != null
      ? [sequence]
      : switch (n) {
          5 => [Prayer.daily],
          6 => [
              [...Prayer.daily, Prayer.jumuah],
              [Prayer.fajr, Prayer.sunrise, ...Prayer.daily.skip(1)],
            ],
          7 => [
              [Prayer.fajr, Prayer.sunrise, ...Prayer.daily.skip(1), Prayer.jumuah],
            ],
          _ => <List<Prayer>>[],
        };
  if (templates.isEmpty || templates.first.length != n) {
    return Labelling(List.filled(n, null), false, null);
  }
  final orders = order != null ? [order] : ReadingOrder.values;

  final candidates = <(double, List<Prayer?>, ReadingOrder)>[];
  for (final o in orders) {
    final indices = _ordered(slots, o);
    for (final t in templates) {
      final labels = List<Prayer?>.filled(n, null);
      final assigned = <(Prayer, int)>[];
      for (var k = 0; k < n; k++) {
        final prayer = t[k];
        labels[indices[k]] = prayer;
        final m = slots[indices[k]].minutes12;
        if (m != null) assigned.add((prayer, to24h(prayer, m)));
      }
      candidates.add((sequencePenalty(assigned), labels, o));
    }
  }
  // Stable: earlier orders/templates win ties.
  var best = candidates.first;
  for (final c in candidates) {
    if (c.$1 < best.$1) best = c;
  }
  final rivals = candidates.where((c) =>
      !_sameLabels(c.$2, best.$2) && c.$1 < best.$1 + 1);
  final confident = (order != null && sequence != null) ||
      (best.$1 < 0.5 && rivals.isEmpty);
  return Labelling(best.$2, confident, best.$3);
}

bool _sameLabels(List<Prayer?> a, List<Prayer?> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Slot indices in reading order.
List<int> _ordered(List<Slot> slots, ReadingOrder order) {
  final byRows = order == ReadingOrder.rtlRows || order == ReadingOrder.ltrRows;
  final rtl = order == ReadingOrder.rtlRows || order == ReadingOrder.rtlColumns;
  final sizes = [for (final s in slots) s.size]..sort();
  final tolerance = 0.6 * sizes[sizes.length ~/ 2];

  // Group into lines (rows or columns) along the primary axis.
  double primary(Slot s) => byRows ? s.y : s.x;
  double secondary(Slot s) => byRows ? s.x : s.y;
  final idx = List<int>.generate(slots.length, (i) => i)
    ..sort((a, b) => primary(slots[a]).compareTo(primary(slots[b])));
  final lines = <List<int>>[];
  for (final i in idx) {
    if (lines.isNotEmpty) {
      final line = lines.last;
      final mean =
          line.map((j) => primary(slots[j])).reduce((a, b) => a + b) / line.length;
      if ((primary(slots[i]) - mean).abs() < tolerance) {
        line.add(i);
        continue;
      }
    }
    lines.add([i]);
  }
  // Rows go top→bottom; columns go right→left for RTL, left→right for LTR.
  final orderedLines = byRows || !rtl ? lines : lines.reversed.toList();
  final out = <int>[];
  for (final line in orderedLines) {
    line.sort((a, b) => secondary(slots[a]).compareTo(secondary(slots[b])));
    // Within a row: right→left for RTL. Within a column: top→bottom.
    out.addAll(byRows && rtl ? line.reversed : line);
  }
  return out;
}
