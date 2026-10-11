/// Authentication methods a server can offer.
enum AuthMethod {
  /// Username and password exchanged for a bearer token at `/auth/login`.
  password,

  /// A bearer token issued by the masjid, pasted into the app.
  token;

  static AuthMethod? parse(Object? s) => switch (s) {
        'password' => password,
        'token' => token,
        _ => null,
      };
}

/// Where a volunteer's account stands (`GET /auth/check`).
enum VolunteerStatus {
  /// Registered; the masjid hasn't approved them yet.
  pending,

  /// May send prayer times.
  approved,

  /// Approval was withdrawn, or the request was declined.
  revoked;

  /// Unknown or missing values count as approved, for servers that only
  /// issue tokens to trusted people.
  static VolunteerStatus parse(Object? s) => switch (s) {
        'pending' => pending,
        'revoked' => revoked,
        _ => approved,
      };
}

/// A volunteer, as `GET /auth/check` describes them.
class Volunteer {
  final String? name;
  final VolunteerStatus status;

  const Volunteer(this.name, this.status);
}

/// `GET /info`: who the server is and what it accepts.
class ServerInfo {
  final int version;
  final String masjidName;

  /// IANA time zone of the masjid, e.g. `America/New_York`, if given.
  final String? timezone;
  final List<AuthMethod> authMethods;

  /// Whether volunteers can register from the app right now.
  final bool canRegister;

  /// Prayer keys the server stores; null means all.
  final List<String>? prayers;
  final bool acceptsAdhan;
  final bool acceptsImage;

  /// Photos older than this are rejected by the server, if set.
  final int? maxAgeMinutes;

  const ServerInfo({
    required this.version,
    required this.masjidName,
    this.timezone,
    required this.authMethods,
    this.canRegister = true,
    this.prayers,
    this.acceptsAdhan = true,
    this.acceptsImage = false,
    this.maxAgeMinutes,
  });

  factory ServerInfo.fromJson(Map<String, Object?> j) {
    if (j['api'] != 'snap-salat') {
      throw const FormatException(
          'Not a Snap Salat API (expected "api": "snap-salat")');
    }
    final masjid = (j['masjid'] as Map?)?.cast<String, Object?>() ?? {};
    final auth = (j['auth'] as Map?)?.cast<String, Object?>() ?? {};
    final accepts = (j['accepts'] as Map?)?.cast<String, Object?>() ?? {};
    final methods = [
      for (final m in (auth['methods'] as List?) ?? const ['password'])
        if (AuthMethod.parse(m) case final AuthMethod method) method
    ];
    if (methods.isEmpty) {
      throw const FormatException('Server offers no supported sign-in method');
    }
    return ServerInfo(
      version: (j['version'] as num?)?.toInt() ?? 1,
      masjidName: masjid['name'] as String? ?? 'Unnamed masjid',
      timezone: masjid['timezone'] as String?,
      authMethods: methods,
      canRegister: methods.contains(AuthMethod.password) &&
          (auth['register'] as bool? ?? true),
      prayers: (accepts['prayers'] as List?)?.cast<String>(),
      acceptsAdhan: accepts['adhan'] as bool? ?? true,
      acceptsImage: accepts['image'] as bool? ?? false,
      maxAgeMinutes: (j['max_age_minutes'] as num?)?.toInt(),
    );
  }
}

/// A signed-in session.
class Session {
  final String accessToken;

  /// When the token stops working, if the server said.
  final DateTime? expiresAt;
  final String? userName;

  const Session(this.accessToken, {this.expiresAt, this.userName});

  bool get expired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  Map<String, Object?> toJson() => {
        'access_token': accessToken,
        if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
        if (userName != null) 'user_name': userName,
      };

  factory Session.fromJson(Map<String, Object?> j) => Session(
        j['access_token'] as String,
        expiresAt: j['expires_at'] == null
            ? null
            : DateTime.tryParse(j['expires_at'] as String),
        userName: j['user_name'] as String?,
      );
}

/// What the app sends to `POST /prayer-times`.
class PrayerTimesSubmission {
  /// When the photo was taken, ISO 8601 with UTC offset when known,
  /// e.g. `2026-10-09T16:53:38-04:00`.
  final String capturedAt;

  /// Where [capturedAt] came from: `exif`, `camera` (taken in the app just
  /// now) or `file` (file timestamp, least reliable). It can't be edited
  /// in the app, so it can't be faked there.
  final String capturedAtSource;

  /// Local date the times apply from, `YYYY-MM-DD`.
  final String date;

  /// Congregation times, prayer key (`fajr`…`isha`, `jumuah`) → `HH:MM`
  /// (24-hour, masjid local).
  final Map<String, String> iqamah;

  /// Start times, prayer key (incl. `sunrise`) → `HH:MM`, if shown.
  final Map<String, String> adhan;

  /// The display's own clock reading, `HH:MM`, if it has one.
  final String? displayClock;

  final Map<String, Object?> recognition;
  final Map<String, Object?> client;

  /// SHA-256 of the photo (hex), always sent so servers can deduplicate.
  final String? imageSha256;

  /// The photo itself (JPEG, base64), only sent if the server accepts it.
  final String? imageJpegBase64;

  const PrayerTimesSubmission({
    required this.capturedAt,
    required this.capturedAtSource,
    required this.date,
    this.iqamah = const {},
    this.adhan = const {},
    this.displayClock,
    this.recognition = const {},
    this.client = const {},
    this.imageSha256,
    this.imageJpegBase64,
  });

  bool get isEmpty => iqamah.isEmpty && adhan.isEmpty;

  Map<String, Object?> toJson({DateTime? now}) => {
        'captured_at': capturedAt,
        'captured_at_source': capturedAtSource,
        'submitted_at': isoWithOffset(now ?? DateTime.now()),
        'date': date,
        'iqamah': iqamah,
        if (adhan.isNotEmpty) 'adhan': adhan,
        if (displayClock != null) 'display_clock': displayClock,
        if (recognition.isNotEmpty) 'recognition': recognition,
        if (client.isNotEmpty) 'client': client,
        if (imageSha256 != null || imageJpegBase64 != null)
          'image': {
            if (imageSha256 != null) 'sha256': imageSha256,
            if (imageJpegBase64 != null) 'jpeg_base64': imageJpegBase64,
          },
      };
}

/// Server's answer to a submission.
class SubmitResult {
  final String status;
  final String? message;

  const SubmitResult(this.status, this.message);
}

/// The times a server currently has (`GET /prayer-times`, optional).
class CurrentTimes {
  final String? capturedAt;
  final String? updatedAt;
  final Map<String, String> iqamah;
  final Map<String, String> adhan;

  const CurrentTimes(
      {this.capturedAt,
      this.updatedAt,
      this.iqamah = const {},
      this.adhan = const {}});

  factory CurrentTimes.fromJson(Map<String, Object?> j) => CurrentTimes(
        capturedAt: j['captured_at'] as String?,
        updatedAt: j['updated_at'] as String?,
        iqamah: ((j['iqamah'] as Map?) ?? {}).cast<String, String>(),
        adhan: ((j['adhan'] as Map?) ?? {}).cast<String, String>(),
      );
}

/// ISO 8601 local time with its UTC offset, e.g. `2026-10-09T16:53:38-04:00`.
String isoWithOffset(DateTime t) {
  final local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final o = local.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final abs = o.abs();
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)}T${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}
