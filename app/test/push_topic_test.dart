import 'package:flutter_test/flutter_test.dart';
import 'package:snap_salat/services/push_service.dart';
import 'package:snap_salat/widgets/current_times_card.dart';

void main() {
  test('topic names match the relay’s (relay/test/relay.test.mjs)', () {
    expect(timesTopic(Uri.parse('https://masjid.test/snap-salat')),
        'times_c051032315d11586be3c26ea735d702201ad231d');
    expect(timesTopic(Uri.parse('HTTPS://Masjid.Test:443/snap-salat/')),
        timesTopic(Uri.parse('https://masjid.test/snap-salat')));
    expect(canonicalApi(Uri.parse('https://masjid.test:8443/x/')),
        'https://masjid.test:8443/x');
  });

  test('photo ages read naturally', () {
    final now = DateTime(2026, 10, 17, 9);
    expect(describeAge(DateTime(2026, 10, 17, 6, 5), now: now),
        'today at 6:05 AM');
    expect(describeAge(DateTime(2026, 10, 16, 16, 53), now: now),
        'yesterday at 4:53 PM');
    expect(describeAge(DateTime(2026, 10, 9, 16, 53), now: now),
        '8 days ago (Oct 9)');
  });
}
