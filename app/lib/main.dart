import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
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

class SnapSalatApp extends StatelessWidget {
  final AppState state;
  const SnapSalatApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Snap Salat',
        debugShowCheckedModeBanner: false,
        theme: Brand.theme(),
        home: const HomeScreen(),
      ),
    );
  }
}
