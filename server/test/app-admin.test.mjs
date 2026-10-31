// Admins in the app, and push notifications through the relay.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDb } from '../src/db.mjs';
import { createApp } from '../src/app.mjs';
import { hashPassword } from '../src/util.mjs';

const RELAY = 'https://relay.test';
const API_URL = 'https://masjid.test/snap-salat';

let server, base, dir, store;
let relayCalls = [];
let relayReply = () => ({ sent: 1, invalid_tokens: [] });

// Calls to the relay are recorded; anything else goes to the real fetch.
const fetchImpl = async (url, init) => {
  if (String(url).startsWith(RELAY)) {
    relayCalls.push({ url: String(url), body: JSON.parse(init.body) });
    return new Response(JSON.stringify(relayReply()), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  return fetch(url, init);
};

before(async () => {
  dir = mkdtempSync(join(tmpdir(), 'snap-salat-'));
  store = openDb(join(dir, 'test.db'));
  store.createAdmin('imam', await hashPassword('admin-password'));
  store.saveSettings({
    masjid_name: 'Test Masjid', timezone: 'America/New_York',
    push_enabled: '1', push_relay_url: RELAY, push_api_url: API_URL,
  });
  server = createApp({ store, dataDir: dir, secureCookies: false, fetchImpl, limits: { registerPerHour: 1000, loginPerMinute: 1000 } });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  server.close();
  rmSync(dir, { recursive: true });
});

beforeEach(() => {
  relayCalls = [];
  relayReply = () => ({ sent: 1, invalid_tokens: [] });
});

const api = (path, { method = 'GET', body, token } = {}) =>
  fetch(`${base}/snap-salat${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });

const login = async (username, password) =>
  (await (await api('/auth/login', { method: 'POST', body: { username, password } })).json());

const fcmToken = (n) => `fcm-token-${n}-${'x'.repeat(40)}`;

async function volunteer(username) {
  await api('/auth/register', { method: 'POST', body: { username, password: 'volunteer-pass', name: `Name ${username}` } });
  await server.idle();
  return (await login(username, 'volunteer-pass')).access_token;
}

test('info tells the app which relay sends notifications', async () => {
  const info = await (await api('/info')).json();
  assert.deepEqual(info.push, { relay: RELAY });
});

test('an admin signs in to the app with their admin-page password', async () => {
  const res = await login('imam', 'admin-password');
  assert.equal(res.user.role, 'admin');
  assert.equal(res.user.status, 'approved');
  const check = await (await api('/auth/check', { token: res.access_token })).json();
  assert.deepEqual(check.user, { name: 'imam', username: 'imam', status: 'approved', role: 'admin' });
  assert.equal((await login('imam', 'wrong')).error, 'invalid_credentials');
  // Volunteers can't take an admin's name.
  const taken = await api('/auth/register', { method: 'POST', body: { username: 'IMAM', password: 'volunteer-pass', name: 'X' } });
  assert.equal(taken.status, 409);
});

test('admins list, approve and revoke volunteers; volunteers cannot', async () => {
  const admin = (await login('imam', 'admin-password')).access_token;
  const vToken = await volunteer('yusuf');
  const { volunteers } = await (await api('/volunteers', { token: admin })).json();
  const yusuf = volunteers.find((v) => v.username === 'yusuf');
  assert.equal(yusuf.status, 'pending');
  assert.equal(yusuf.name, 'Name yusuf');
  assert.ok(yusuf.registered_at);
  assert.equal('password_hash' in yusuf, false);

  assert.equal((await api('/volunteers', { token: vToken })).status, 403);
  assert.equal((await api('/volunteers')).status, 401);
  assert.equal((await api(`/volunteers/${yusuf.id}/approve`, { method: 'POST', token: vToken })).status, 403);

  const approved = await (await api(`/volunteers/${yusuf.id}/approve`, { method: 'POST', token: admin })).json();
  assert.equal(approved.volunteer.status, 'approved');
  assert.equal(store.userByName('yusuf').decided_by, 'imam');
  assert.equal((await api('/volunteers/99999/approve', { method: 'POST', token: admin })).status, 404);

  const revoked = await (await api(`/volunteers/${yusuf.id}/revoke`, { method: 'POST', token: admin })).json();
  assert.equal(revoked.volunteer.status, 'revoked');
  assert.equal((await api('/auth/check', { token: vToken })).status, 401);
});

test('an admin can send times from the app', async () => {
  const admin = (await login('imam', 'admin-password')).access_token;
  const res = await api('/prayer-times', {
    method: 'POST', token: admin,
    body: { captured_at: new Date().toISOString(), captured_at_source: 'camera', date: '2026-10-09', iqamah: { isha: '20:15' } },
  });
  assert.equal(res.status, 201);
  assert.equal(store.submissions(1)[0].user_name, 'imam');
});

test('admins with the app hear about new volunteers; volunteers hear when approved', async () => {
  const admin = (await login('imam', 'admin-password')).access_token;
  assert.equal((await api('/push/register', { method: 'POST', token: admin, body: { token: fcmToken(1), platform: 'android' } })).status, 200);
  assert.equal((await api('/push/register', { method: 'POST', token: admin, body: { token: 'short' } })).status, 422);
  assert.equal((await api('/push/register', { method: 'POST', body: { token: fcmToken(9) } })).status, 401);

  relayCalls = [];
  const vToken = await volunteer('amina');
  assert.equal(relayCalls.length, 1);
  assert.equal(relayCalls[0].url, `${RELAY}/v1/notify`);
  assert.deepEqual(relayCalls[0].body.tokens, [fcmToken(1)]);
  assert.equal(relayCalls[0].body.event, 'approval_waiting');
  assert.equal(relayCalls[0].body.api, API_URL);
  assert.equal(relayCalls[0].body.masjid, 'Test Masjid');
  assert.ok(relayCalls[0].body.count >= 1);

  await api('/push/register', { method: 'POST', token: vToken, body: { token: fcmToken(2), platform: 'ios' } });
  relayCalls = [];
  const id = store.userByName('amina').id;
  await api(`/volunteers/${id}/approve`, { method: 'POST', token: admin });
  await server.idle();
  assert.deepEqual(relayCalls.map((c) => [c.body.event, c.body.tokens]), [['approved', [fcmToken(2)]]]);

  // Approving again isn't news.
  relayCalls = [];
  await api(`/volunteers/${id}/approve`, { method: 'POST', token: admin });
  await server.idle();
  assert.equal(relayCalls.length, 0);
});

test('tokens the relay reports as invalid are forgotten; unregister needs only the token', async () => {
  const admin = (await login('imam', 'admin-password')).access_token;
  await api('/push/register', { method: 'POST', token: admin, body: { token: fcmToken(3) } });
  await api('/push/register', { method: 'POST', token: admin, body: { token: fcmToken(4) } });
  relayReply = () => ({ sent: 1, invalid_tokens: [fcmToken(3)] });
  await volunteer('bilal');
  assert.equal(store.adminPushTokens().includes(fcmToken(3)), false);
  assert.equal(store.adminPushTokens().includes(fcmToken(4)), true);
  await api('/push/unregister', { method: 'POST', body: { token: fcmToken(4) } });
  assert.equal(store.adminPushTokens().includes(fcmToken(4)), false);
});

test('the relay is told when the published times change, not otherwise', async () => {
  const admin = (await login('imam', 'admin-password')).access_token;
  const send = async (iqamah, minutesAgo) => {
    const res = await api('/prayer-times', {
      method: 'POST', token: admin,
      body: { captured_at: new Date(Date.now() - minutesAgo * 60_000).toISOString(), captured_at_source: 'camera', date: '2026-10-09', iqamah },
    });
    assert.equal(res.status, 201);
    await server.idle();
  };
  // Earlier tests may have left a newer photo; start after it.
  await new Promise((r) => setTimeout(r, 5));
  relayCalls = [];
  await send({ fajr: '06:10' }, 0);
  assert.deepEqual(relayCalls.map((c) => c.body), [{ api: API_URL, masjid: 'Test Masjid', event: 'times_changed' }]);
  relayCalls = [];
  await new Promise((r) => setTimeout(r, 5));
  await send({ fajr: '06:10' }, 0);
  assert.equal(relayCalls.length, 0);
});

test('nothing goes to the relay while notifications are off', async () => {
  store.saveSettings({ push_enabled: '0' });
  try {
    assert.equal((await (await api('/info')).json()).push, undefined);
    relayCalls = [];
    await volunteer('khalid');
    assert.equal(relayCalls.length, 0);
  } finally {
    store.saveSettings({ push_enabled: '1' });
  }
});
