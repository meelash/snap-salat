import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snap_salat_api/snap_salat_api.dart';
import 'package:test/test.dart';

void main() {
  group('parseBaseUrl', () {
    test('adds https and trims the trailing slash', () {
      expect(SnapSalatApi.parseBaseUrl('masjid.example.org/api/').toString(),
          'https://masjid.example.org/api');
    });

    test('rejects plain http', () {
      expect(() => SnapSalatApi.parseBaseUrl('http://masjid.example.org'),
          throwsFormatException);
    });

    test('allows http for local development when asked', () {
      expect(
          SnapSalatApi.parseBaseUrl('http://192.168.1.20:8080',
                  allowInsecureLocal: true)
              .toString(),
          'http://192.168.1.20:8080');
      expect(
          () => SnapSalatApi.parseBaseUrl('http://example.org',
              allowInsecureLocal: true),
          throwsFormatException);
    });
  });

  group('requests', () {
    late List<http.Request> sent;
    SnapSalatApi api(http.Response Function(http.Request) handler) {
      sent = [];
      return SnapSalatApi(Uri.parse('https://m.example/snap'),
          client: MockClient((req) async {
        sent.add(req);
        return handler(req);
      }));
    }

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status,
            headers: {'content-type': 'application/json'});

    test('info', () async {
      final info = await api((_) => json({
            'api': 'snap-salat',
            'version': 1,
            'masjid': {'name': 'Test Masjid', 'timezone': 'America/New_York'},
            'auth': {
              'methods': ['password', 'token']
            },
          })).info();
      expect(sent.single.url.toString(), 'https://m.example/snap/info');
      expect(info.masjidName, 'Test Masjid');
      expect(info.authMethods, [AuthMethod.password, AuthMethod.token]);
    });

    test('info rejects other APIs', () async {
      expect(api((_) => json({'hello': 'world'})).info(),
          throwsA(isA<ApiException>()));
    });

    test('login and submit', () async {
      final client = api((req) => switch (req.url.path) {
            '/snap/auth/login' => json({
                'access_token': 'abc',
                'token_type': 'Bearer',
                'expires_in': 3600,
                'user': {'name': 'Imam'},
              }),
            '/snap/prayer-times' => json({'status': 'accepted'}, 201),
            _ => json({}, 404),
          });
      final session = await client.login('imam', 'secret');
      expect(session.accessToken, 'abc');
      expect(session.userName, 'Imam');
      expect(jsonDecode(sent.last.body),
          {'username': 'imam', 'password': 'secret'});

      final result = await client.submit(
          session.accessToken,
          const PrayerTimesSubmission(
            capturedAt: '2026-10-09T16:53:38-04:00',
            capturedAtSource: 'exif',
            date: '2026-10-09',
            iqamah: {'fajr': '06:15', 'dhuhr': '13:30', 'jumuah': '13:45'},
          ));
      expect(result.status, 'accepted');
      expect(sent.last.headers['Authorization'], 'Bearer abc');
      final body = jsonDecode(sent.last.body) as Map;
      expect(body['captured_at'], '2026-10-09T16:53:38-04:00');
      expect(body['iqamah'],
          {'fajr': '06:15', 'dhuhr': '13:30', 'jumuah': '13:45'});
      expect(body['submitted_at'], isA<String>());
    });

    test('maps errors', () async {
      final client = api((req) => json(
          {'error': 'stale', 'message': 'A newer photo was already sent.'},
          409));
      try {
        await client.submit(
            't',
            const PrayerTimesSubmission(
                capturedAt: 'x',
                capturedAtSource: 'exif',
                date: 'd',
                iqamah: {'fajr': '06:00'}));
        fail('expected an exception');
      } on ApiException catch (e) {
        expect(e.stale, isTrue);
        expect(e.code, 'stale');
        expect(e.message, 'A newer photo was already sent.');
      }
    });

    test('401 means sign in again', () async {
      final client = api((_) => http.Response('', 401));
      await expectLater(
          client.check('old'),
          throwsA(isA<ApiException>()
              .having((e) => e.needsSignIn, 'needsSignIn', isTrue)));
    });
  });
}
