import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:http/http.dart' as http;

import 'models.dart';

/// Something went wrong talking to the server.
class ApiException implements Exception {
  /// HTTP status, or 0 for network/format problems.
  final int status;

  /// Machine-readable code from the server's `error` field, if any.
  final String? code;
  final String message;

  /// Per-field problems from a `422` answer, e.g. `{"password": "…"}`.
  final Map<String, String> fields;

  const ApiException(this.status, this.message,
      {this.code, this.fields = const {}});

  /// The token is missing, wrong or expired: sign in again.
  bool get needsSignIn => status == 401;

  /// The server already has times from a newer photo.
  bool get stale => status == 409;

  /// Signed in, but the masjid hasn't approved (or has revoked) this
  /// volunteer.
  bool get notApproved => code == 'not_approved';

  @override
  String toString() => message;
}

/// Talks to one masjid's Snap Salat endpoint.
class SnapSalatApi {
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;

  SnapSalatApi(this.baseUrl,
      {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _http = client ?? http.Client();

  /// Parses and checks a user-entered base URL.
  ///
  /// HTTPS is required, because the app sends credentials. Plain HTTP is
  /// only allowed for local development hosts when [allowInsecureLocal].
  static Uri parseBaseUrl(String input, {bool allowInsecureLocal = false}) {
    var text = input.trim();
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException("That doesn't look like a web address.");
    }
    if (uri.scheme != 'https') {
      if (!(uri.scheme == 'http' && allowInsecureLocal && _isLocal(uri.host))) {
        throw const FormatException(
            'The address must start with https:// (a secure connection).');
      }
    }
    // Normalise: no query/fragment, no trailing slash.
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: path, query: null, fragment: null);
  }

  static bool _isLocal(String host) {
    if (host == 'localhost' || host == '10.0.2.2') return true;
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 127 ||
        b[0] == 10 ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
  }

  Uri _url(String path) => baseUrl.replace(path: '${baseUrl.path}$path');

  /// `GET /info`.
  Future<ServerInfo> info() async {
    final j = await _send('GET', '/info');
    try {
      return ServerInfo.fromJson(j);
    } on FormatException catch (e) {
      throw ApiException(0, e.message);
    } on TypeError {
      throw const ApiException(0, 'The server sent an unexpected /info reply.');
    }
  }

  /// `POST /auth/login` with a username and password.
  Future<Session> login(String username, String password) async {
    final j = await _send('POST', '/auth/login',
        body: {'username': username, 'password': password});
    final token = j['access_token'];
    if (token is! String || token.isEmpty) {
      throw const ApiException(0, 'The server did not return a token.');
    }
    final expiresIn = (j['expires_in'] as num?)?.toInt();
    final user = (j['user'] as Map?)?['name'] as String?;
    return Session(token,
        expiresAt: expiresIn == null
            ? null
            : DateTime.now().add(Duration(seconds: expiresIn)),
        userName: user ?? username);
  }

  /// `POST /auth/register`: ask for an account. It starts pending until
  /// the masjid approves it. Returns the server's message.
  Future<String?> register({
    required String username,
    required String password,
    required String name,
    String? contact,
    String? note,
  }) async {
    final j = await _send('POST', '/auth/register', body: {
      'username': username,
      'password': password,
      'name': name,
      if (contact != null && contact.isNotEmpty) 'contact': contact,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return j['message'] as String?;
  }

  /// `GET /auth/check`: is this token still good, and is the volunteer
  /// approved yet?
  Future<Volunteer> check(String token) async {
    final j = await _send('GET', '/auth/check', token: token);
    final user = (j['user'] as Map?) ?? const {};
    return Volunteer(
        user['name'] as String?, VolunteerStatus.parse(user['status']));
  }

  /// `POST /prayer-times`.
  Future<SubmitResult> submit(String token, PrayerTimesSubmission s) async {
    if (s.isEmpty) {
      throw const ApiException(0, 'There are no times to send.');
    }
    final j =
        await _send('POST', '/prayer-times', token: token, body: s.toJson());
    return SubmitResult(
        j['status'] as String? ?? 'accepted', j['message'] as String?);
  }

  /// `GET /prayer-times`, optional. Null if the server doesn't offer it.
  Future<CurrentTimes?> current() async {
    try {
      return CurrentTimes.fromJson(await _send('GET', '/prayer-times'));
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 405 || e.status == 401) return null;
      rethrow;
    }
  }

  Future<Map<String, Object?>> _send(String method, String path,
      {String? token, Map<String, Object?>? body}) async {
    final req = http.Request(method, _url(path))
      ..headers['Accept'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(
          await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw const ApiException(0, 'The server took too long to answer.');
    } on Exception catch (e) {
      throw ApiException(0, "Couldn't reach the server ($e).");
    }

    Map<String, Object?> json = const {};
    if (res.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map) json = decoded.cast<String, Object?>();
      } on FormatException {
        if (res.statusCode < 300) {
          throw ApiException(
              res.statusCode, 'The server sent something other than JSON.');
        }
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;

    final message = json['message'] as String? ??
        switch (res.statusCode) {
          401 => 'Please sign in again.',
          403 => "This account isn't allowed to update these times.",
          404 => 'Not found. Check the address.',
          409 => 'The server already has times from a newer photo.',
          422 || 400 => 'The server rejected the times.',
          _ => 'The server returned an error (${res.statusCode}).',
        };
    final fields = json['fields'];
    throw ApiException(res.statusCode, message,
        code: json['error'] as String?,
        fields: fields is Map
            ? {for (final e in fields.entries) '${e.key}': '${e.value}'}
            : const {});
  }

  void close() => _http.close();
}
