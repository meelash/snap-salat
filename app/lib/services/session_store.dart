import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:snap_salat_api/snap_salat_api.dart';

/// Keeps sign-in tokens in the platform keystore, one per endpoint.
class SessionStore {
  // Encrypted with the Android Keystore / iOS Keychain by default.
  final _storage = const FlutterSecureStorage();

  String _key(Uri api) => 'session:$api';

  Future<Session?> read(Uri api) async {
    final s = await _storage.read(key: _key(api));
    if (s == null) return null;
    try {
      return Session.fromJson((jsonDecode(s) as Map).cast());
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Uri api, Session session) =>
      _storage.write(key: _key(api), value: jsonEncode(session.toJson()));

  Future<void> delete(Uri api) => _storage.delete(key: _key(api));
}
