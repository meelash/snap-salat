// node --test relay/test/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { createRelay, publishedIqamah, describeChanges } from '../src/relay.mjs';
import { canonicalApi, timesTopic } from '../src/topic.mjs';
import { fcmClient } from '../src/fcm.mjs';

const API = 'https://masjid.test/snap-salat';

test('topic names: one per masjid, however its address is spelled', async () => {
  assert.equal(canonicalApi('HTTPS://Masjid.Test:443/snap-salat/'), API);
  assert.equal(canonicalApi('https://masjid.test:8443/x?y=1#z'), 'https://masjid.test:8443/x');
  assert.equal(canonicalApi('ftp://masjid.test'), null);
  assert.equal(canonicalApi('not a url'), null);
  // Same vector as app/test/push_topic_test.dart.
  assert.equal(await timesTopic('https://masjid.test/snap-salat'), 'times_c051032315d11586be3c26ea735d702201ad231d');
  assert.equal(await timesTopic('HTTPS://MASJID.test/snap-salat/'), await timesTopic(API));
});

test('changes are described in 12-hour time; sunset Maghrib is not news', () => {
  assert.deepEqual(publishedIqamah({ iqamah: { fajr: '06:15', maghrib: '18:01', bogus: '1', isha: 'late' }, maghrib: { source: 'sunset' } }),
    { fajr: '06:15' });
  assert.deepEqual(describeChanges({ fajr: '06:15', isha: '20:15' }, { fajr: '06:00', isha: '20:15', jumuah: '13:30' }),
    ['Fajr 6:00 AM (was 6:15 AM)', "Jumu'ah 1:30 PM"]);
});

function setup({ times, info = { masjid: { name: 'Masjid Al-Noor' } }, invalid = [] } = {}) {
  const sent = [];
  const store = new Map();
  let published = times;
  const relay = createRelay({
    fcm: { send: async (m) => (sent.push(m), invalid.includes(m.token) ? 'invalid_token' : 'sent') },
    kv: { get: async (k) => store.get(k) ?? null, put: async (k, v) => store.set(k, v) },
    fetchImpl: async (url) => {
      if (url === `${API}/prayer-times`) return Response.json(published);
      if (url === `${API}/info`) return Response.json(info);
      return new Response('nope', { status: 404 });
    },
  });
  const call = async (body, method = 'POST') => {
    const res = await relay(new Request('https://relay.test/v1/notify', { method, body: method === 'POST' ? JSON.stringify(body) : undefined }));
    return { status: res.status, body: await res.json() };
  };
  return { call, sent, setTimes: (t) => { published = t; } };
}

test('times_changed reads the masjid’s own times and notifies its topic only on real changes', async () => {
  const r = setup({ times: { iqamah: { fajr: '06:15', isha: '20:15' } } });
  const first = await r.call({ event: 'times_changed', api: `${API}/` });
  assert.deepEqual(first, { status: 200, body: { sent: 1, invalid_tokens: [] } });
  assert.equal(r.sent[0].topic, await timesTopic(API));
  assert.deepEqual(r.sent[0].notification, { title: 'Masjid Al-Noor: prayer times updated', body: 'Fajr 6:15 AM · Isha 8:15 PM' });
  assert.deepEqual(r.sent[0].data, { type: 'times_changed', api: API });

  // Asked again with nothing new: nothing sent, so a caller can't spam.
  assert.deepEqual((await r.call({ event: 'times_changed', api: API })).body, { sent: 0, reason: 'unchanged' });
  assert.equal(r.sent.length, 1);

  r.setTimes({ masjid: { name: 'Al-Noor' }, iqamah: { fajr: '06:15', isha: '20:00' } });
  await r.call({ event: 'times_changed', api: API });
  assert.deepEqual(r.sent[1].notification, { title: 'Al-Noor: iqamah times changed', body: 'Isha 8:00 PM (was 8:15 PM)' });
});

test('approval_waiting and approved go to the given devices, with fixed wording', async () => {
  const r = setup({ invalid: ['gone-token'] });
  const res = await r.call({ event: 'approval_waiting', api: API, masjid: 'Al-Noor\n<b>', tokens: ['admin-token', 'gone-token'], count: 2 });
  assert.deepEqual(res.body, { sent: 1, invalid_tokens: ['gone-token'] });
  assert.equal(r.sent[0].token, 'admin-token');
  assert.deepEqual(r.sent[0].notification, { title: 'Al-Noor <b>', body: '2 volunteers are waiting for your approval.' });
  assert.deepEqual(r.sent[0].data, { type: 'approval_waiting', api: API });

  await r.call({ event: 'approved', api: API, masjid: 'Al-Noor', tokens: ['volunteer-token'] });
  assert.equal(r.sent.at(-1).data.type, 'approved');
  assert.match(r.sent.at(-1).notification.body, /approved/);
});

test('bad requests are refused', async () => {
  const r = setup();
  assert.equal((await r.call({ event: 'approved', api: 'http://masjid.test/x', tokens: [] })).status, 422);
  assert.equal((await r.call({ event: 'approved', api: API, tokens: Array(41).fill('t') })).status, 422);
  assert.equal((await r.call({ event: 'party', api: API, tokens: [] })).status, 422);
  assert.equal((await r.call({ event: 'times_changed', api: 'https://elsewhere.test' })).status, 422);
  assert.equal((await r.call(null, 'GET')).status, 405);
});

test('fcm client signs in with the service account and spots dead tokens', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const account = {
    project_id: 'snap-salat-test',
    client_email: 'relay@snap-salat-test.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  };
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (url === 'https://oauth2.googleapis.com/token') {
      const jwt = new URLSearchParams(String(init.body)).get('assertion');
      const [h, p, sig] = jwt.split('.');
      const ok = createVerify('RSA-SHA256').update(`${h}.${p}`).verify(publicKey, Buffer.from(sig, 'base64url'));
      assert.ok(ok, 'JWT signature verifies');
      const claims = JSON.parse(Buffer.from(p, 'base64url'));
      assert.equal(claims.iss, account.client_email);
      assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
      return Response.json({ access_token: 'ya29.test', expires_in: 3600 });
    }
    const { message } = JSON.parse(init.body);
    assert.equal(init.headers.Authorization, 'Bearer ya29.test');
    if (message.token === 'dead') {
      return Response.json({ error: { message: 'Requested entity was not found.', details: [{ errorCode: 'UNREGISTERED' }] } }, { status: 404 });
    }
    return Response.json({ name: 'projects/snap-salat-test/messages/1' });
  };
  const fcm = fcmClient(account, { fetchImpl });
  assert.equal(await fcm.send({ token: 'alive', notification: { title: 't', body: 'b' } }), 'sent');
  assert.equal(await fcm.send({ token: 'dead' }), 'invalid_token');
  assert.equal(calls[1].url, 'https://fcm.googleapis.com/v1/projects/snap-salat-test/messages:send');
  // The access token is reused.
  assert.equal(calls.filter((c) => c.url.includes('oauth2')).length, 1);
});
