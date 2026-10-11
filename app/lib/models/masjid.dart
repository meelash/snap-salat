import 'package:salat_reader/salat_reader.dart';

/// A masjid endpoint: from the directory, or typed in by the user.
class Masjid {
  /// Directory id (`us/connecticut/hamden/masjid-name`), null if manual.
  final String? id;
  final String name;
  final String? country, region, city, area;
  final Uri api;
  final String? website;
  final DisplayHints? display;

  const Masjid({
    this.id,
    required this.name,
    this.country,
    this.region,
    this.city,
    this.area,
    required this.api,
    this.website,
    this.display,
  });

  bool get fromDirectory => id != null;

  String get place => [area, city, region, country]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(', ');

  factory Masjid.fromJson(Map<String, Object?> j) => Masjid(
        id: j['id'] as String?,
        name: j['name'] as String,
        country: j['country'] as String?,
        region: j['region'] as String?,
        city: j['city'] as String?,
        area: j['area'] as String?,
        api: Uri.parse(j['api'] as String),
        website: j['website'] as String?,
        display: j['display'] is Map
            ? DisplayHints.fromJson((j['display'] as Map).cast())
            : null,
      );

  Map<String, Object?> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        if (country != null) 'country': country,
        if (region != null) 'region': region,
        if (city != null) 'city': city,
        if (area != null) 'area': area,
        'api': api.toString(),
        if (website != null) 'website': website,
        if (display != null) 'display': display!.toJson(),
      };
}

/// Optional hints from the directory about the masjid's display.
class DisplayHints {
  /// `analog-clocks` or `text`.
  final String? type;
  final String? order;
  final List<String>? sequence;
  final bool? currentTimeClock;

  const DisplayHints(
      {this.type, this.order, this.sequence, this.currentTimeClock});

  factory DisplayHints.fromJson(Map<String, Object?> j) => DisplayHints(
        type: j['type'] as String?,
        order: j['order'] as String?,
        sequence: (j['sequence'] as List?)?.cast<String>(),
        currentTimeClock: j['current_time_clock'] as bool?,
      );

  Map<String, Object?> toJson() => {
        if (type != null) 'type': type,
        if (order != null) 'order': order,
        if (sequence != null) 'sequence': sequence,
        if (currentTimeClock != null) 'current_time_clock': currentTimeClock,
      };

  AnalogLayout get analogLayout => AnalogLayout(
        order: ReadingOrder.parse(order),
        sequence: sequence
            ?.map((s) => Prayer.values.where((p) => p.name == s).firstOrNull)
            .whereType<Prayer>()
            .toList(),
        hasCurrentTimeClock: currentTimeClock,
      );
}
