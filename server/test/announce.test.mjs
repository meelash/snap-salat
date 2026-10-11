// node --test server/test/
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDb } from '../src/db.mjs';
import { createApp } from '../src/app.mjs';
import { detectChanges, buildPost } from '../src/announce.mjs';

// A stand-in for the bulletin-board's /api/v1, with the same shapes.
let posts = [], failNext = false, categoryActive = true, list, listUrl;
let server, base, dir, store, token, captureMinutesAgo = 600;

before(async () => {
  list = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : null;
    if (req.headers.authorization !== 'Bearer bb_test') {
      res.writeHead(401).end();
      return;
    }
    if (req.method === 'POST' && req.url === '/api/v1/posts') {
      if (failNext) {
        failNext = false;
        res.writeHead(403, { 'Content-Type': 'application/json' }).end(JSON.stringify({ error: 'Key lacks posts:submit scope' }));
        return;
      }
      posts.push({ body, key: req.headers['idempotency-key'] });
      const id = `0b7f1c2e-${String(posts.length).padStart(4, '0')}`;
      res.writeHead(201, { 'Content-Type': 'application/json' })
        .end(JSON.stringify({ id, status: body.submit ? 'pending_approval' : 'draft', template: body.template }));
    } else if (req.method === 'GET' && req.url.startsWith('/api/v1/posts/')) {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ id: 'x', status: 'approved' }));
    } else if (req.method === 'GET' && req.url === '/api/v1/posts') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ posts: [] }));
    } else if (req.method === 'GET' && req.url === '/api/v1/categories') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({
        categories: categoryActive ? [{ slug: 'prayer-times', name: 'Prayer times' }] : [],
        templates: [{ key: 'prayer_times', label: 'Prayer time change', defaultCategory: 'prayer-times', fields: [
          { name: 'effectiveDate', label: 'Effective date', type: 'date', required: true },
          ...['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha', 'jumuah'].map((name) => ({ name, label: name, type: 'text' })),
        ] }],
      }));
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise((r) => list.listen(0, '127.0.0.1', r));
  listUrl = `http://127.0.0.1:${list.address().port}`;

  dir = mkdtempSync(join(tmpdir(), 'snap-salat-announce-'));
  store = openDb(join(dir, 'test.db'));
  store.saveSettings({
    timezone: 'America/New_York',
    announce_enabled: '1',
    announce_url: listUrl,
    announce_token: 'bb_test',
    max_age_minutes: '10080',
  });
  server = createApp({ store, dataDir: dir, secureCookies: false });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}/snap-salat`;

  await fetch(`${base}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'vol', password: 'volunteer-pass', name: 'Vol' }),
  });
  store.setUserStatus(store.userByName('vol').id, 'approved', 'test');
  token = (await (await fetch(`${base}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'vol', password: 'volunteer-pass' }),
  })).json()).access_token;
});

after(() => {
  server.close();
  list.close();
  rmSync(dir, { recursive: true });
});

beforeEach(() => {
  posts = [];
});

/** Submits times from a photo taken a little later than the previous one. */
async function submit(iqamah, { minutesAgo } = {}) {
  captureMinutesAgo -= 10;
  const at = new Date(Date.now() - (minutesAgo ?? captureMinutesAgo) * 60_000);
  const res = await fetch(`${base}/prayer-times`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ captured_at: at.toISOString(), date: '2026-11-02', iqamah }),
  });
  await server.idle();
  return res.status;
}

const week = { fajr: '06:15', dhuhr: '13:30', asr: '16:00', maghrib: '18:00', isha: '19:30', jumuah: '13:45' };

test('the first upload sets the times without announcing', async () => {
  assert.equal(await submit(week), 201);
  assert.equal(posts.length, 0);
});

test('an upload with the same times announces nothing', async () => {
  assert.equal(await submit(week), 201);
  assert.equal(posts.length, 0);
});

test('a real change drafts one announcement with all the times', async () => {
  assert.equal(await submit({ ...week, fajr: '06:00', isha: '19:15' }), 201);
  assert.equal(posts.length, 1);
  const { body, key } = posts[0];
  assert.equal(body.template, 'prayer_times');
  assert.equal(body.submit, true);
  assert.deepEqual(body.templateData, {
    effectiveDate: '2026-11-02',
    fajr: '6:00 AM', dhuhr: '1:30 PM', asr: '4:00 PM', maghrib: '6:00 PM', isha: '7:15 PM', jumuah: '1:45 PM',
  });
  assert.match(body.bodyText, /Fajr 6:00 AM \(was 6:15 AM\), Isha 7:15 PM \(was 7:30 PM\)/);
  assert.match(key, /^prayer-times-2026-11-02-[0-9a-f]{10}$/);
  const [a] = store.announcements(1);
  assert.equal(a.status, 'sent');
  assert.equal(a.remote_id, '0b7f1c2e-0001');
});

test('a photo older than the last announcement never announces', async () => {
  // Older than the announced photo but newer than nothing: the server
  // already refuses it as stale, and nothing is drafted either way.
  const status = await submit({ ...week, fajr: '05:45' }, { minutesAgo: 900 });
  assert.equal(status, 409);
  assert.equal(posts.length, 0);
});

test('maghrib changes are ignored while maghrib follows sunset', async () => {
  store.saveSettings({ maghrib_mode: 'sunset', maghrib_offset: '5', latitude: '41.3962', longitude: '-72.8973' });
  assert.equal(await submit({ ...week, fajr: '06:00', isha: '19:15', maghrib: '17:55' }), 201);
  assert.equal(posts.length, 0);
  assert.equal(await submit({ ...week, fajr: '06:00', isha: '19:15', asr: '15:00', maghrib: '17:50' }), 201);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].body.templateData.maghrib, 'Sunset + 5 min');
  store.saveSettings({ maghrib_mode: 'board' });
});

test('a failure is recorded without affecting the volunteer, and can be retried', async () => {
  failNext = true;
  assert.equal(await submit({ ...week, fajr: '06:00', isha: '19:15', asr: '14:45' }), 201);
  const [failed] = store.announcements(1);
  assert.equal(failed.status, 'failed');
  assert.equal(failed.error, 'HTTP 403: Key lacks posts:submit scope');
  assert.equal(posts.length, 0);

  // Retrying from the admin page: same request and idempotency key.
  const { announcer } = await import('../src/announce.mjs');
  const again = await announcer({ store }).retry(failed.id);
  assert.equal(again.status, 'sent');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].key, failed.idempotency_key);
});

test('announcements are skipped when turned off', async () => {
  store.saveSettings({ announce_enabled: '0' });
  assert.equal(await submit({ ...week, fajr: '05:30', asr: '14:30', isha: '19:15' }), 201);
  assert.equal(posts.length, 0);
  store.saveSettings({ announce_enabled: '1' });
});

test('connection test checks the key, template and category', async () => {
  const { announcer } = await import('../src/announce.mjs');
  const ok = await announcer({ store }).test();
  assert.equal(ok.ok, true, ok.message);
  assert.deepEqual(ok.fields, ['effectiveDate', 'fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha', 'jumuah']);
  assert.match(ok.message, /Prayer time change/);

  categoryActive = false;
  const noCategory = await announcer({ store }).test();
  assert.equal(noCategory.ok, false);
  assert.match(noCategory.message, /"prayer-times" category/);
  categoryActive = true;

  store.saveSettings({ announce_token: 'bb_wrong' });
  const bad = await announcer({ store }).test();
  assert.equal(bad.ok, false);
  assert.match(bad.message, /API key/);
  store.saveSettings({ announce_token: 'bb_test' });
});

test('change detection ignores prayers set for the first time', () => {
  const settings = { maghrib_mode: 'board' };
  assert.deepEqual(detectChanges({ fajr: '06:00' }, { fajr: '06:00', isha: '19:00' }, settings), []);
  assert.deepEqual(detectChanges({ fajr: '06:00' }, { fajr: '05:45' }, settings), [{ key: 'fajr', from: '06:00', to: '05:45' }]);
  const post = buildPost({ settings: { ...settings, announce_submit: '0' }, iqamah: { fajr: '05:45' },
    changes: [{ key: 'fajr', from: '06:00', to: '05:45' }], effectiveDate: '2026-11-02' });
  assert.equal(post.submit, false);
  assert.match(post.bodyText, /^Iqamah times change from Monday, November 2: Fajr 5:45 AM \(was 6:00 AM\)\.$/);
});
