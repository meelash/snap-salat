import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/volunteers_screen.dart';
import 'services/push_service.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled fonts are SIL Open Font License; list them on the licences page.
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in [
      ('Figtree', 'assets/fonts/OFL-Figtree.txt'),
      ('Reem Kufi', 'assets/fonts/OFL-ReemKufi.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks(
          [name], await rootBundle.loadString(file));
    }
  });
  final state = AppState();
  runApp(SnapSalatApp(state: state));
  state.init();
}

/// Makes [AppState] available to every screen.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  /// In build methods: rebuilds when the state changes.
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// In initState and callbacks: no rebuild dependency.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class SnapSalatApp extends StatefulWidget {
  final AppState state;
  const SnapSalatApp({super.key, required this.state});

  @override
  State<SnapSalatApp> createState() => _SnapSalatAppState();
}

class _SnapSalatAppState extends State<SnapSalatApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _subscriptions = <StreamSubscription<RemoteMessage>>[];

  @override
  void initState() {
    super.initState();
    final push = widget.state.push;
    if (push.available) {
      _subscriptions
        ..add(push.foreground.listen((m) => _onPush(m, opened: false)))
        ..add(push.opened.listen((m) => _onPush(m, opened: true)));
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  /// A notification arrived while the app is open, or was tapped.
  void _onPush(RemoteMessage m, {required bool opened}) {
    final state = widget.state;
    final api = Uri.tryParse(m.data['api'] as String? ?? '');
    final masjid = state.masjid;
    // Only about the chosen masjid; others are just shown by the system.
    if (api == null ||
        masjid == null ||
        canonicalApi(api) != canonicalApi(masjid.api)) {
      return;
    }
    switch (m.data['type']) {
      case 'times_changed':
        state.refreshCurrent();
      case 'approved':
        state.refreshStatus();
      case 'approval_waiting':
        state.refreshPending();
        if (opened && state.isAdmin) {
          _navigator.currentState?.push(
              MaterialPageRoute(builder: (_) => const VolunteersScreen()));
        }
    }
    // Android doesn't show notifications while the app is open (iOS does).
    final text = m.notification?.body;
    if (!opened &&
        text != null &&
        defaultTargetPlatform == TargetPlatform.android) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Snap Salat',
        debugShowCheckedModeBanner: false,
        theme: Brand.theme(),
        navigatorKey: _navigator,
        scaffoldMessengerKey: _messenger,
        home: const HomeScreen(),
      ),
    );
  }
}
