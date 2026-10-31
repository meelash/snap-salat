import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snap_salat_api/snap_salat_api.dart';

import 'models/masjid.dart';
import 'services/push_service.dart';
import 'services/registry_service.dart';
import 'services/session_store.dart';

/// App-wide state: the chosen masjid and whether we're signed in to it.
class AppState extends ChangeNotifier {
  static const _masjidKey = 'masjid.selected';
  static String _followKey(Uri api) => 'push.times:$api';

  final registry = RegistryService();
  final push = PushService();
  final _sessions = SessionStore();
  late SharedPreferences _prefs;

  Masjid? _masjid;
  Session? _session;
  ServerInfo? _serverInfo;
  VolunteerStatus? _status;
  bool _admin = false;
  int? _pending;
  CurrentTimes? _current;
  bool _currentLoaded = false;
  StreamSubscription<String>? _tokenRefresh;

  /// The session whose push token the server has, so it's sent once.
  String? _pushRegistered;

  Masjid? get masjid => _masjid;

  /// Whether the masjid has approved this volunteer. Null until checked.
  VolunteerStatus? get status => _status;
  bool get approved => _status == VolunteerStatus.approved;

  /// Signed in with one of the masjid's admin accounts: may approve
  /// volunteers.
  bool get isAdmin => _admin && signedIn;

  /// Volunteers waiting for approval, for admins. Null until checked.
  int? get pendingCount => isAdmin ? _pending : null;
  Session? get session => _session;
  ServerInfo? get serverInfo => _serverInfo;
  bool get signedIn => _session != null && !_session!.expired;

  /// The times the masjid's website has now (`GET /prayer-times`). Null if
  /// not loaded yet, or the server doesn't share them ([currentLoaded]).
  CurrentTimes? get current => _current;
  bool get currentLoaded => _currentLoaded;

  /// For screenshots and tests, which can't reach a server.
  @visibleForTesting
  void debugSetCurrent(CurrentTimes times) {
    _current = times;
    _currentLoaded = true;
    notifyListeners();
  }

  /// Whether this masjid's server sends notifications this app receives.
  bool get canNotify => push.servesRelay(_serverInfo?.pushRelay);

  /// Notify me when this masjid's times change.
  bool get followsTimes =>
      _masjid != null && (_prefs.getBool(_followKey(_masjid!.api)) ?? false);

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
    if (_masjid != null) {
      refreshServerInfo();
      refreshCurrent();
    }
    if (signedIn) refreshStatus();
    _tokenRefresh = push.tokenRefresh.listen((_) {
      _pushRegistered = null;
      _maybeRegisterPush();
    });
  }

  @override
  void dispose() {
    _tokenRefresh?.cancel();
    super.dispose();
  }

  /// Asks the server whether this volunteer is approved yet
  /// (`GET /auth/check`). Signs out if the token no longer works.
  Future<VolunteerStatus?> refreshStatus() async {
    final api = this.api, session = _session;
    if (api == null || session == null) return null;
    try {
      final me = await api.check(session.accessToken);
      _status = me.status;
      _admin = me.isAdmin;
      notifyListeners();
      if (_admin) refreshPending();
      _maybeRegisterPush();
    } on ApiException catch (e) {
      if (e.needsSignIn) await signOut();
    }
    return _status;
  }

  /// How many volunteers are waiting, for an admin.
  Future<void> refreshPending() async {
    final api = this.api, session = _session;
    if (api == null || session == null || !_admin) return;
    try {
      final all = await api.volunteers(session.accessToken);
      setPendingCount(
          all.where((v) => v.status == VolunteerStatus.pending).length);
    } on ApiException {
      // Shown on the volunteers screen when it matters.
    }
  }

  void setPendingCount(int n) {
    _pending = n;
    notifyListeners();
  }

  Future<ServerInfo?> refreshServerInfo() async {
    final api = this.api;
    if (api == null) return null;
    try {
      _serverInfo = await api.info();
      notifyListeners();
      _maybeRegisterPush();
    } on ApiException {
      // Offline or misconfigured; screens show errors when they need it.
    }
    return _serverInfo;
  }

  /// Loads the times the website has now.
  Future<CurrentTimes?> refreshCurrent() async {
    final api = this.api, masjid = _masjid;
    if (api == null) return null;
    try {
      final times = await api.current();
      if (_masjid != masjid) return _current;
      _current = times;
      _currentLoaded = true;
    } on ApiException {
      // Offline: keep what we had.
      _currentLoaded = true;
    }
    notifyListeners();
    return _current;
  }

  Future<void> selectMasjid(Masjid m, {ServerInfo? info}) async {
    final previous = _masjid;
    if (previous != null && previous.api != m.api && followsTimes) {
      // Notifications follow the chosen masjid.
      unawaited(push.followTimes(previous.api, false).catchError((_) {}));
    }
    _masjid = m;
    _serverInfo = info;
    _session = await _sessions.read(m.api);
    _status = null;
    _admin = false;
    _pending = null;
    _current = null;
    _currentLoaded = false;
    await _prefs.setString(_masjidKey, jsonEncode(m.toJson()));
    notifyListeners();
    if (info == null) refreshServerInfo();
    refreshCurrent();
    if (followsTimes) {
      unawaited(push.followTimes(m.api, true).catchError((_) {}));
    }
    if (signedIn) refreshStatus();
  }

  /// Turns "notify me when the times change" on or off. Returns false if
  /// notifications aren't allowed on this phone.
  Future<bool> setFollowTimes(bool follow) async {
    final masjid = _masjid;
    if (masjid == null) return false;
    if (follow && !await push.requestPermission()) return false;
    try {
      await push.followTimes(masjid.api, follow);
    } catch (e) {
      debugPrint('topic subscription failed: $e');
      return false;
    }
    await _prefs.setBool(_followKey(masjid.api), follow);
    notifyListeners();
    return true;
  }

  /// Gives the server this install's push token, once the server's
  /// details and the account's status are both known. Admins hear about
  /// new volunteers; pending volunteers about being approved.
  Future<void> _maybeRegisterPush() async {
    final api = this.api, session = _session;
    if (api == null || session == null || !canNotify) return;
    if (!(_admin || _status == VolunteerStatus.pending)) return;
    if (_pushRegistered == session.accessToken) return;
    _pushRegistered = session.accessToken;
    if (!await push.requestPermission()) return;
    final token = await push.token();
    if (token == null) return;
    try {
      await api.registerPush(session.accessToken, token,
          platform: Platform.operatingSystem);
    } on ApiException catch (e) {
      _pushRegistered = null;
      debugPrint('push registration failed: $e');
    }
  }

  Future<void> saveSession(Session s) async {
    _session = s;
    _status = null;
    await _sessions.write(_masjid!.api, s);
    notifyListeners();
    await refreshStatus();
  }

  Future<void> signOut() async {
    final api = this.api;
    if (api != null && canNotify) {
      // Stop this account's notifications on this phone.
      final token = await push.token();
      if (token != null) {
        unawaited(api.unregisterPush(token).then((_) {}, onError: (_) {}));
      }
    }
    if (_masjid != null) await _sessions.delete(_masjid!.api);
    _session = null;
    _status = null;
    _admin = false;
    _pending = null;
    notifyListeners();
  }
}
