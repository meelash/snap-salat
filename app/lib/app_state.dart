import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snap_salat_api/snap_salat_api.dart';

import 'models/masjid.dart';
import 'services/registry_service.dart';
import 'services/session_store.dart';

/// App-wide state: the chosen masjid and whether we're signed in to it.
class AppState extends ChangeNotifier {
  static const _masjidKey = 'masjid.selected';

  final registry = RegistryService();
  final _sessions = SessionStore();
  late SharedPreferences _prefs;

  Masjid? _masjid;
  Session? _session;
  ServerInfo? _serverInfo;
  VolunteerStatus? _status;

  Masjid? get masjid => _masjid;

  /// Whether the masjid has approved this volunteer. Null until checked.
  VolunteerStatus? get status => _status;
  bool get approved => _status == VolunteerStatus.approved;
  Session? get session => _session;
  ServerInfo? get serverInfo => _serverInfo;
  bool get signedIn => _session != null && !_session!.expired;

  /// Plain-HTTP endpoints are only allowed in debug builds, for testing
  /// against a server on your own computer.
  bool get allowInsecureLocal => kDebugMode;

  SnapSalatApi? get api => _masjid == null ? null : SnapSalatApi(_masjid!.api);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await registry.loadLocal();
    final saved = _prefs.getString(_masjidKey);
    if (saved != null) {
      try {
        _masjid = Masjid.fromJson((jsonDecode(saved) as Map).cast());
        _session = await _sessions.read(_masjid!.api);
      } catch (_) {
        _masjid = null;
      }
    }
    notifyListeners();
    // Refresh the directory and server details in the background.
    registry.refresh().then((_) => notifyListeners());
    if (_masjid != null) refreshServerInfo();
    if (signedIn) refreshStatus();
  }

  /// Asks the server whether this volunteer is approved yet
  /// (`GET /auth/check`). Signs out if the token no longer works.
  Future<VolunteerStatus?> refreshStatus() async {
    final api = this.api, session = _session;
    if (api == null || session == null) return null;
    try {
      _status = (await api.check(session.accessToken)).status;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.needsSignIn) await signOut();
    }
    return _status;
  }

  Future<ServerInfo?> refreshServerInfo() async {
    final api = this.api;
    if (api == null) return null;
    try {
      _serverInfo = await api.info();
      notifyListeners();
    } on ApiException {
      // Offline or misconfigured; screens show errors when they need it.
    }
    return _serverInfo;
  }

  Future<void> selectMasjid(Masjid m, {ServerInfo? info}) async {
    _masjid = m;
    _serverInfo = info;
    _session = await _sessions.read(m.api);
    _status = null;
    await _prefs.setString(_masjidKey, jsonEncode(m.toJson()));
    notifyListeners();
    if (info == null) refreshServerInfo();
    if (signedIn) refreshStatus();
  }

  Future<void> saveSession(Session s) async {
    _session = s;
    await _sessions.write(_masjid!.api, s);
    notifyListeners();
    await refreshStatus();
  }

  Future<void> signOut() async {
    if (_masjid != null) await _sessions.delete(_masjid!.api);
    _session = null;
    _status = null;
    notifyListeners();
  }
}
