import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';

/// A masjid API address in one canonical spelling: lower-case scheme and
/// host, no default port, no trailing slash, query or fragment. The relay
/// spells it the same way (relay/src/topic.mjs).
String canonicalApi(Uri api) {
  final scheme = api.scheme.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = api.hasPort && api.port != defaultPort ? ':${api.port}' : '';
  final path = api.path.replaceFirst(RegExp(r'/+$'), '');
  return '$scheme://${api.host.toLowerCase()}$port$path';
}

/// The FCM topic for a masjid's "times changed" notifications.
String timesTopic(Uri api) =>
    'times_${sha256.convert(utf8.encode(canonicalApi(api))).toString().substring(0, 40)}';

/// Push notifications through Firebase Cloud Messaging, when the app is
/// built with a Firebase project ([PushConfig]); otherwise [available] is
/// false and nothing here does anything.
class PushService {
  Future<bool>? _ready;

  bool get available => PushConfig.options != null;

  /// Whether a server's notifications reach this app: it must use the
  /// relay this app was built for.
  bool servesRelay(Uri? relay) =>
      available &&
      relay != null &&
      canonicalApi(relay) == canonicalApi(Uri.parse(PushConfig.relay));

  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  /// Starts Firebase once. False if push isn't built in or won't start.
  Future<bool> init() => _ready ??= _init();

  Future<bool> _init() async {
    final options = PushConfig.options;
    if (options == null) return false;
    try {
      await Firebase.initializeApp(options: options);
      // Show notifications on iOS even while the app is open (Android
      // doesn't; the app shows them itself, see main.dart).
      await _fm.setForegroundNotificationPresentationOptions(
          alert: true, sound: true);
      return true;
    } catch (e) {
      debugPrint('push unavailable: $e');
      return false;
    }
  }

  /// Asks to show notifications (Android 13+, iOS). True if allowed.
  Future<bool> requestPermission() async {
    if (!await init()) return false;
    final s = await _fm.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// This install's push token, or null if there isn't one (yet).
  Future<String?> token() async {
    if (!await init()) return null;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // FCM needs the APNs token first, which can take a moment.
        for (var i = 0; i < 5 && await _fm.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      // The classic registration token, which the relay sends to with the
      // FCM HTTP v1 API. (firebase_messaging 17 also offers FID
      // registration, register()/onRegistered; move to it once the relay
      // sends to FIDs.)
      // ignore: deprecated_member_use
      return await _fm.getToken();
    } catch (e) {
      debugPrint('no push token: $e');
      return null;
    }
  }

  Stream<String> get tokenRefresh async* {
    // ignore: deprecated_member_use
    if (await init()) yield* _fm.onTokenRefresh;
  }

  Future<void> followTimes(Uri api, bool follow) async {
    if (!await init()) return;
    final topic = timesTopic(api);
    if (follow) {
      await _fm.subscribeToTopic(topic);
    } else {
      await _fm.unsubscribeFromTopic(topic);
    }
  }

  /// Notifications that arrive while the app is open.
  Stream<RemoteMessage> get foreground async* {
    if (await init()) yield* FirebaseMessaging.onMessage;
  }

  /// Notifications the user tapped, including the one that opened the app.
  Stream<RemoteMessage> get opened async* {
    if (!await init()) return;
    final first = await _fm.getInitialMessage();
    if (first != null) yield first;
    yield* FirebaseMessaging.onMessageOpenedApp;
  }
}
