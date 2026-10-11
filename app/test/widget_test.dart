import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snap_salat/app_state.dart';
import 'package:snap_salat/main.dart';

void main() {
  testWidgets('home screen asks for a masjid first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(SnapSalatApp(state: AppState()));
    expect(find.text('Choose your masjid'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);
  });
}
