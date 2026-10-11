import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:snap_salat_api/snap_salat_api.dart';
import 'package:test/test.dart';

/// The Dart client against the example server in server/, end to end:
/// register → pending → approved by the masjid → send times.
void main() {
  final node = Process.runSync('which', ['node']).exitCode == 0;
  if (!node) {
    test('example server interop', () {}, skip: 'Node.js not installed');
    return;
  }
  Process? server;
  late Directory dir;
  late SnapSalatApi api;
  final env = <String, String>{};

  Future<ProcessResult> cli(List<String> args) => Process.run(
      'node',
      [
        '--disable-warning=ExperimentalWarning',
        '../../server/server.mjs',
        ...args
      ],
      environment: env);

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('snap-salat-');
    env['DATA_DIR'] = dir.path;
    server = await Process.start('node',
        ['--disable-warning=ExperimentalWarning', '../../server/server.mjs'],
        environment: {...env, 'PORT': '0'});
    final port = Completer<int>();
    server!.stdout.transform(utf8.decoder).listen((line) {
      final m = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line);
      if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
    });
    server!.stderr.transform(utf8.decoder).listen(stderr.write);
    final p = await port.future.timeout(const Duration(seconds: 10));
    api = SnapSalatApi(SnapSalatApi.parseBaseUrl(
        'http://localhost:$p/snap-salat',
        allowInsecureLocal: true));
  });

  tearDownAll(() async {
    server?.kill();
    await dir.delete(recursive: true);
  });

  test('register, wait for approval, then send times', () async {
    final info = await api.info();
    expect(info.authMethods, contains(AuthMethod.password));
    expect(info.canRegister, isTrue);

    await api.register(
        username: 'yusuf', password: 'volunteer-pass', name: 'Yusuf A');
    final session = await api.login('yusuf', 'volunteer-pass');
    expect((await api.check(session.accessToken)).status,
        VolunteerStatus.pending);

    final now = DateTime.now().subtract(const Duration(minutes: 2));
    final submission = PrayerTimesSubmission(
      capturedAt: isoWithOffset(now),
      capturedAtSource: 'camera',
      date: isoWithOffset(now).substring(0, 10),
      iqamah: const {'fajr': '06:15', 'maghrib': '18:33', 'jumuah': '13:45'},
      displayClock: '16:53',
    );
    await expectLater(
        api.submit(session.accessToken, submission),
        throwsA(isA<ApiException>()
            .having((e) => e.notApproved, 'notApproved', isTrue)));

    // The masjid approves them (here from the server's command line).
    expect((await cli(['approve-user', 'yusuf'])).exitCode, 0);
    expect((await api.check(session.accessToken)).status,
        VolunteerStatus.approved);

    final result = await api.submit(session.accessToken, submission);
    expect(result.status, 'accepted');
    final current = await api.current();
    expect(current!.iqamah['maghrib'], '18:33');
    expect(current.iqamah['jumuah'], '13:45');
  });

  test('wrong password is a 401 the app can act on', () async {
    await expectLater(
        api.login('yusuf', 'nope'),
        throwsA(isA<ApiException>()
            .having((e) => e.needsSignIn, 'needsSignIn', isTrue)
            .having(
                (e) => e.message, 'message', 'Wrong username or password.')));
  });
}
