import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Where the app finds things on the web. Change these if you fork.
class AppConfig {
  /// The masjid directory, built from registry/ by tools/build-registry.mjs.
  static final registryUrl = Uri.parse(
      'https://raw.githubusercontent.com/meelash/snap-salat/main/registry/index.json');

  /// User guide (GitHub Pages).
  static final helpUrl = Uri.parse('https://meelash.github.io/snap-salat/');

  /// How to add a masjid to the directory.
  static final addMasjidUrl =
      Uri.parse('https://meelash.github.io/snap-salat/adding-a-masjid.html');

  /// The "display not read well" issue form, prefilled (GitHub issue forms
  /// take field values as query parameters named by field id).
  static Uri reportDisplayUrl({String? kind, String? truth, String? notes}) =>
      Uri.https('github.com', '/meelash/snap-salat/issues/new', {
        'template': 'new-display.yml',
        'title': 'Display not read well',
        if (kind != null) 'kind': kind,
        if (truth != null) 'truth': truth,
        if (notes != null) 'notes': notes,
      });
}

/// Push notifications, through the relay in relay/. Off unless the app is
/// built with the Firebase project's details, e.g.
///
///     flutter run --dart-define-from-file=push.json
///
/// (push.example.json shows the keys; relay/README.md how to get them.)
/// None of these values is secret; the relay holds the only key.
class PushConfig {
  static const relay = String.fromEnvironment('PUSH_RELAY_URL');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _androidAppId =
      String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  static const _androidApiKey =
      String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

  /// Firebase options for this platform, or null when push isn't built in.
  static FirebaseOptions? get options {
    if (relay.isEmpty || _projectId.isEmpty || _senderId.isEmpty) return null;
    final (appId, apiKey) = switch (defaultTargetPlatform) {
      TargetPlatform.android => (_androidAppId, _androidApiKey),
      TargetPlatform.iOS => (_iosAppId, _iosApiKey),
      _ => ('', ''),
    };
    if (appId.isEmpty || apiKey.isEmpty) return null;
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: _senderId,
      projectId: _projectId,
      iosBundleId: _iosBundleId.isEmpty ? null : _iosBundleId,
    );
  }
}
