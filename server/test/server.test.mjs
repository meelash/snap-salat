// node --test server/test/
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDb } from '../src/db.mjs';
import { createApp } from '../src/app.mjs';
import { hashPassword } from '../src/util.mjs';
import { sunsetMinutes } from '../src/sun.mjs';
import { widgetFragment } from '../src/public.mjs';

let server, base, dir, store;

before(async () => {
  dir = mkdtempSync(join(tmpdir(), 'snap-salat-'));
  store = openDb(join(dir, 'test.db'));
  store.createAdmin('admin', await hashPassword('admin-password'));
  store.saveSettings({ masjid_name: 'Test Masjid', timezone: 'America/New_York' });
  server = createApp({ store, dataDir: dir, secureCookies: false, limits: { registerPerHour: 1000, loginPerMinute: 1000 } });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  server.close();
  rmSync(dir, { recursive: true });
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

const minutesAgo = (m) => new Date(Date.now() - m * 60_000).toISOString();

async function registerAndLogin(username) {
  const reg = await api('/auth/register', {
    method: 'POST',
    body: { username, password: 'volunteer-pass', name: `Name ${username}` },
  });
  assert.equal(reg.status, 201);
  const login = await (await api('/auth/login', { method: 'POST', body: { username, password: 'volunteer-pass' } })).json();
  return login.access_token;
}

test('info advertises password sign-in and registration', async () => {
  const info = await (await api('/info')).json();
  assert.equal(info.api, 'snap-salat');
  assert.equal(info.masjid.name, 'Test Masjid');
  assert.deepEqual(info.auth, { methods: ['password'], register: true });
});

test('registration is validated and usernames are unique', async () => {
  const bad = await api('/auth/register', { method: 'POST', body: { username: 'x', password: 'short', name: '' } });
  assert.equal(bad.status, 422);
  const fields = (await bad.json()).fields;
  assert.ok(fields.username && fields.password && fields.name);
  await registerAndLogin('unique1');
  const dup = await api('/auth/register', { method: 'POST', body: { username: 'UNIQUE1', password: 'volunteer-pass', name: 'X' } });
  assert.equal(dup.status, 409);
});

test('a pending volunteer can sign in and check, but not submit until approved', async () => {
  const token = await registerAndLogin('pending1');
  const check = await (await api('/auth/check', { token })).json();
  assert.equal(check.user.status, 'pending');

  const body = { captured_at: minutesAgo(5), captured_at_source: 'camera', date: '2026-10-09', iqamah: { fajr: '06:15' } };
  const denied = await api('/prayer-times', { method: 'POST', token, body });
  assert.equal(denied.status, 403);
  assert.equal((await denied.json()).error, 'not_approved');

  store.setUserStatus(store.userByName('pending1').id, 'approved', 'test');
  assert.equal((await (await api('/auth/check', { token })).json()).user.status, 'approved');
  const ok = await api('/prayer-times', { method: 'POST', token, body });
  assert.equal(ok.status, 201);
});

test('revoking ends existing sessions', async () => {
  const token = await registerAndLogin('revoked1');
  store.setUserStatus(store.userByName('revoked1').id, 'approved', 'test');
  store.setUserStatus(store.userByName('revoked1').id, 'revoked', 'test');
  assert.equal((await api('/auth/check', { token })).status, 401);
});

test('submissions: merge, stale photos, validation, public JSON', async () => {
  const token = await registerAndLogin('approved1');
  store.setUserStatus(store.userByName('approved1').id, 'approved', 'test');
  const send = (body) => api('/prayer-times', { method: 'POST', token, body });

  assert.equal((await send({ captured_at: minutesAgo(3), iqamah: { dhuhr: '13:30', jumuah: '13:45' } })).status, 201);
  assert.equal((await send({ captured_at: minutesAgo(2), iqamah: { asr: '17:00' } })).status, 201);
  const stale = await send({ captured_at: minutesAgo(60), iqamah: { asr: '16:00' } });
  assert.equal(stale.status, 409);
  const invalid = await send({ captured_at: minutesAgo(1), iqamah: { fajr: '6:15', lunch: '12:00' } });
  assert.equal(invalid.status, 422);
  const old = await send({ captured_at: minutesAgo(3 * 24 * 60), iqamah: { fajr: '06:00' } });
  assert.equal(old.status, 422);
  assert.match((await old.json()).message, /more than 24 hours ago\. Please take a new photo/);
  const badPlace = await send({ captured_at: minutesAgo(1), iqamah: { fajr: '06:00' }, location: { lat: 'x' } });
  assert.equal(badPlace.status, 422);
  assert.equal((await send({ captured_at: minutesAgo(1), iqamah: { isha: '20:15' }, location: { lat: 41.3429, lng: -72.9266 } })).status, 201);
  const row = store.submissions(1)[0];
  assert.equal(row.photo_lat, 41.3429);
  assert.equal(row.photo_lng, -72.9266);

  const pub = await fetch(`${base}/prayer-times.json`);
  assert.equal(pub.headers.get('access-control-allow-origin'), '*');
  const times = await pub.json();
  assert.equal(times.iqamah.dhuhr, '13:30');
  assert.equal(times.iqamah.asr, '17:00');
  assert.equal(times.iqamah.jumuah, '13:45');
});

test('maghrib from sunset plus an offset', async () => {
  store.saveSettings({ maghrib_mode: 'sunset', maghrib_offset: '5', latitude: '41.3962', longitude: '-72.8973' });
  const times = await (await fetch(`${base}/prayer-times.json`)).json();
  assert.equal(times.maghrib.source, 'sunset');
  assert.equal(times.maghrib.offset_minutes, 5);
  const [sh, sm] = times.maghrib.sunset.split(':').map(Number);
  const [mh, mm] = times.iqamah.maghrib.split(':').map(Number);
  assert.equal(mh * 60 + mm - (sh * 60 + sm), 5);
  store.saveSettings({ maghrib_mode: 'board' });
});

test('sunset is right to within a few minutes', () => {
  const near = (date, lat, lng, tz, expected) => {
    const m = sunsetMinutes(date, lat, lng, tz);
    const [h, mi] = expected.split(':').map(Number);
    assert.ok(Math.abs(m - (h * 60 + mi)) <= 3, `${date} ${tz}: ${m} vs ${expected}`);
  };
  near('2026-06-21', 51.5074, -0.1278, 'Europe/London', '21:21');
  near('2026-12-21', 40.7128, -74.006, 'America/New_York', '16:32');
  near('2026-03-20', 21.4225, 39.8262, 'Asia/Riyadh', '18:32');
});

test('widget renders the times and escapes the masjid name', () => {
  store.saveSettings({ masjid_name: 'Masjid <script>' });
  const html = widgetFragment(store, { theme: 'light', accent: '#1E3A8A', showAdhan: false });
  assert.ok(html.includes('Masjid &lt;script&gt;'));
  assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('1:30'));
  store.saveSettings({ masjid_name: 'Test Masjid' });
});

test('widget script and pages are served', async () => {
  assert.match(await (await fetch(`${base}/widget.js`)).text(), /attachShadow/);
  assert.equal((await fetch(`${base}/widget?theme=light`)).status, 200);
  assert.equal((await fetch(`${base}/widget/fragment`)).status, 200);
});

test('admin: sign-in, CSRF protection, approving a volunteer', async () => {
  const page = await fetch(`${base}/admin`, { redirect: 'manual' });
  assert.equal(page.status, 303);

  const login = await fetch(`${base}/admin/login`, {
    method: 'POST',
    redirect: 'manual',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'username=admin&password=admin-password',
  });
  assert.equal(login.status, 303);
  const cookie = login.headers.get('set-cookie').split(';')[0];
  assert.match(login.headers.get('set-cookie'), /HttpOnly; SameSite=Strict/);

  await registerAndLogin('fromadmin');
  const overview = await (await fetch(`${base}/admin`, { headers: { cookie } })).text();
  assert.match(overview, /Name fromadmin/);
  const csrf = /name="_csrf" value="([^"]+)"/.exec(overview)[1];
  const id = store.userByName('fromadmin').id;

  const forged = await fetch(`${base}/admin/users/${id}/approve`, {
    method: 'POST',
    redirect: 'manual',
    headers: { cookie, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: '_csrf=wrong',
  });
  assert.equal(forged.status, 403);
  assert.equal(store.userByName('fromadmin').status, 'pending');

  const approve = await fetch(`${base}/admin/users/${id}/approve`, {
    method: 'POST',
    redirect: 'manual',
    headers: { cookie, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `_csrf=${encodeURIComponent(csrf)}`,
  });
  assert.equal(approve.status, 303);
  assert.equal(store.userByName('fromadmin').status, 'approved');
});

test('admin settings reject bad values', async () => {
  const login = await fetch(`${base}/admin/login`, {
    method: 'POST',
    redirect: 'manual',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'username=admin&password=admin-password',
  });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const html = await (await fetch(`${base}/admin/settings`, { headers: { cookie } })).text();
  const csrf = /name="_csrf" value="([^"]+)"/.exec(html)[1];
  const res = await fetch(`${base}/admin/settings`, {
    method: 'POST',
    headers: { cookie, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      _csrf: csrf, masjid_name: 'X', timezone: 'Mars/Olympus', latitude: '', longitude: '',
      maghrib_mode: 'sunset', max_age_minutes: '1440', widget_accent: '#D4AF5F',
    }).toString(),
  });
  assert.equal(res.status, 422);
  const body = await res.text();
  assert.match(body, /Unknown time zone/);
  assert.match(body, /latitude and longitude/);
  assert.equal(store.settings().timezone, 'America/New_York');
});
