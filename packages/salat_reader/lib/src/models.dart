/// The prayers (and sunrise) that may appear on a masjid display.
enum Prayer {
  fajr,
  sunrise,
  dhuhr,
  asr,
  maghrib,
  isha,
  jumuah;

  String get displayName => switch (this) {
        Prayer.fajr => 'Fajr',
        Prayer.sunrise => 'Sunrise',
        Prayer.dhuhr => 'Dhuhr',
        Prayer.asr => 'Asr',
        Prayer.maghrib => 'Maghrib',
        Prayer.isha => 'Isha',
        Prayer.jumuah => "Jumu'ah",
      };

  /// The five daily prayers in order.
  static const daily = [
    Prayer.fajr,
    Prayer.dhuhr,
    Prayer.asr,
    Prayer.maghrib,
    Prayer.isha
  ];

  /// Plausible window for this prayer in minutes after local midnight.
  /// Used to resolve AM/PM on 12-hour displays and to sanity-check readings.
  /// Isha may run past midnight, so its window extends beyond 1440.
  (int, int) get window => switch (this) {
        Prayer.fajr => (3 * 60, 8 * 60),
        Prayer.sunrise => (4 * 60 + 30, 9 * 60 + 30),
        Prayer.dhuhr => (11 * 60 + 30, 14 * 60 + 30),
        Prayer.jumuah => (11 * 60 + 30, 15 * 60),
        Prayer.asr => (13 * 60 + 30, 19 * 60 + 30),
        Prayer.maghrib => (16 * 60, 22 * 60),
        Prayer.isha => (17 * 60 + 30, 25 * 60 + 30),
      };
}

/// Whether a time is when the congregation starts (iqamah) or when the
/// prayer time begins (adhan / "begins" / "start").
enum TimeKind { iqamah, adhan }

/// A wall-clock time of day, 24-hour.
class Hm implements Comparable<Hm> {
  final int hour;
  final int minute;

  const Hm(this.hour, this.minute)
      : assert(hour >= 0 && hour < 24),
        assert(minute >= 0 && minute < 60);

  factory Hm.fromMinutes(int minutes) {
    final m = minutes % 1440;
    return Hm(m ~/ 60, m % 60);
  }

  /// Parses "HH:MM" (24-hour).
  static Hm? tryParse(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    final h = int.parse(m[1]!), min = int.parse(m[2]!);
    if (h > 23 || min > 59) return null;
    return Hm(h, min);
  }

  int get inMinutes => hour * 60 + minute;

  /// "HH:MM", 24-hour, zero padded. This is the API wire format.
  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String to12h() {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    return '$h:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  int compareTo(Hm other) => inMinutes.compareTo(other.inMinutes);

  @override
  bool operator ==(Object other) =>
      other is Hm && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => inMinutes;
}

/// An axis-aligned region of the (orientation-corrected) source image.
class Region {
  final double left, top, width, height;
  final bool oval;

  const Region(this.left, this.top, this.width, this.height,
      {this.oval = false});

  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  Map<String, Object> toJson() => {
        'left': left.round(),
        'top': top.round(),
        'width': width.round(),
        'height': height.round(),
        if (oval) 'oval': true,
      };
}

/// One time read from the display.
class TimeReading {
  /// Which prayer this is, or null when the reader could not tell.
  Prayer? prayer;
  TimeKind kind;
  Hm time;

  /// 0..1, how sure the reader is of [time] (not of [prayer]).
  double confidence;

  /// Where on the image this time was read from.
  final Region? region;

  /// Free-form detail, e.g. the raw OCR text or hand angles.
  final String? detail;

  TimeReading({
    required this.prayer,
    required this.kind,
    required this.time,
    required this.confidence,
    this.region,
    this.detail,
  });

  Map<String, Object?> toJson() => {
        'prayer': prayer?.name,
        'kind': kind.name,
        'time': time.toString(),
        'confidence': double.parse(confidence.toStringAsFixed(2)),
        if (region != null) 'region': region!.toJson(),
        if (detail != null) 'detail': detail,
      };
}

/// A time the reader knows is on the display but could not read, e.g. a
/// clock whose hands are hidden by glare. The app asks the user for it.
class MissingReading {
  final Prayer? prayer;
  final Region region;
  final String reason;

  const MissingReading(this.prayer, this.region, this.reason);

  Map<String, Object?> toJson() =>
      {'prayer': prayer?.name, 'region': region.toJson(), 'reason': reason};
}

/// Everything a reader extracted from one photo.
class BoardReading {
  /// Which reader produced this, e.g. `analog-clocks` or `text`.
  final String reader;
  final List<TimeReading> times;

  /// The board's "current time" clock, if it has one. Comparing it with the
  /// photo timestamp is a cheap check that the photo is recent and real.
  final TimeReading? displayClock;

  final List<MissingReading> missing;
  final List<String> warnings;
  final int imageWidth, imageHeight;

  BoardReading({
    required this.reader,
    required this.times,
    this.displayClock,
    List<MissingReading>? missing,
    List<String>? warnings,
    required this.imageWidth,
    required this.imageHeight,
  })  : missing = missing ?? [],
        warnings = warnings ?? [];

  /// Overall confidence: the weakest labelled reading.
  double get confidence {
    final labelled = times.where((t) => t.prayer != null);
    if (labelled.isEmpty) return 0;
    return labelled.map((t) => t.confidence).reduce((a, b) => a < b ? a : b);
  }

  Iterable<TimeReading> get unlabelled => times.where((t) => t.prayer == null);

  TimeReading? find(Prayer p, TimeKind kind) {
    for (final t in times) {
      if (t.prayer == p && t.kind == kind) return t;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'reader': reader,
        'confidence': double.parse(confidence.toStringAsFixed(2)),
        'times': [for (final t in times) t.toJson()],
        if (displayClock != null) 'display_clock': displayClock!.toJson(),
        if (missing.isNotEmpty) 'missing': [for (final m in missing) m.toJson()],
        'warnings': warnings,
        'image': {'width': imageWidth, 'height': imageHeight},
      };
}
