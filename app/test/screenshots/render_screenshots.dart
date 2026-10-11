// Renders the app's main screens at phone size for the website.
//
//   cd app && flutter test test/screenshots/render_screenshots.dart --update-goldens
//   # then shrink for the web: magick X.png -resize 780x -colors 256 PNG8:X.png
//
// Writes PNGs to docs/assets/img/. Named without the _test suffix so it isn't
// part of the normal test run.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salat_reader/salat_reader.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snap_salat/app_state.dart';
import 'package:snap_salat/main.dart';
import 'package:snap_salat/screens/review_screen.dart';
import 'package:snap_salat/services/recognition.dart';

// Relative to this file.
const out = '../../../docs/assets/img';

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

Future<void> loadFonts() async {
  await loadFont('Figtree', [
    for (final w in [400, 600, 700, 800]) 'assets/fonts/Figtree-$w.ttf'
  ]);
  await loadFont('ReemKufi',
      ['assets/fonts/ReemKufi-500.ttf', 'assets/fonts/ReemKufi-700.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
  await loadFont('MaterialIcons',
      ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

void phone(WidgetTester tester, {double height = 2340}) {
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 2.75;
}

void main() {
  setUpAll(loadFonts);

  /// App state with the Islamic Center of Hamden chosen.
  Future<AppState> hamden(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'masjid.selected':
          '{"id":"us/connecticut/hamden/islamic-center-of-hamden","name":"Islamic Center of Hamden",'
              '"country":"US","region":"Connecticut","city":"Hamden",'
              '"api":"https://snapsalat.islamiccenterofhamden.org/snap-salat"}',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await tester.runAsync(state.init);
    return state;
  }

  testWidgets('home', (tester) async {
    phone(tester);
    final state = await hamden(tester);
    await tester.pumpWidget(SnapSalatApp(state: state));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('$out/app-home.png'));
  });

  testWidgets('review', (tester) async {
    phone(tester, height: 3420);
    final original =
        File('../sample_images/IMG_20261009_165338219.jpg').readAsBytesSync();
    final display = File('test/screenshots/board-1200.jpg').readAsBytesSync();
    final result = await tester.runAsync(() async {
      final reading = readAnalogBoard(original);
      return RecognitionResult(
          reading,
          captureInfoFor(PhotoInput(original, '', fromCamera: false)),
          'sample');
    });
    final state = await hamden(tester);
    final photo = PhotoInput(display, '', fromCamera: false);
    // The real app shell (theme etc.), with the Review screen pushed.
    await tester.pumpWidget(SnapSalatApp(state: state));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(
        builder: (_) => ReviewScreen(photo: photo, initialResult: result)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Let the photo decode.
    await tester.runAsync(() async {
      final element = tester.element(find.byType(Image));
      await precacheImage(MemoryImage(display), element);
    });
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('$out/app-review.png'));
  });
}
