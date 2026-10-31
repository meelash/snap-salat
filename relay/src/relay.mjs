// The Snap Salat notification relay.
//
// Masjid servers can't hold the app's Firebase key (anyone could then push
// to every user of the app), so they call this relay instead, which does:
//
//   POST /v1/notify
//   {"event": "times_changed", "api": "https://masjid.org/snap-salat"}
//     Reads {api}/prayer-times itself, compares it with what it saw last
//     time, and notifies the masjid's topic of what changed. The text comes
//     from the masjid's own public times, so a caller can't make anything
//     up; at worst it repeats a real change, which is deduplicated.
//   {"event": "approval_waiting" | "approved", "api": …, "masjid": "Name",
//    "tokens": ["<FCM token>", …], "count": 2}
//     Fixed wording to the given devices: admins about volunteers waiting,
//     a volunteer about being approved. Only the masjid server knows these
//     tokens (the app registered them there).
//
// Answers {"sent": n, "invalid_tokens": [...]} so servers can forget
// uninstalled apps. Runs anywhere with fetch and WebCrypto: see worker.mjs
// (Cloudflare) and node.mjs.

import { canonicalApi, timesTopic } from './topic.mjs';

const MAX_TOKENS = 40; // Cloudflare's free plan allows 50 outgoing requests per call
const MAX_BODY = 64 * 1024;
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
const NAMES = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha', jumuah: "Jumu'ah" };

const to12h = (t) => {
  const [h, m] = t.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};

const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
const fail = (status, error, message) => json(status, { error, message });

class BadRequest extends Error {}

/** Short plain text from an untrusted string, for a notification. */
const clean = (s, max) => String(s ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);

/**
 * The iqamah times a masjid publishes, as {key: "HH:MM"}, leaving out
 * Maghrib when it's calculated from sunset (it changes every day; that's
 * not news).
 */
export function publishedIqamah(times) {
  const out = {};
  for (const key of Object.keys(NAMES)) {
    const t = times?.iqamah?.[key];
    if (typeof t === 'string' && HHMM.test(t)) out[key] = t;
  }
  if (times?.maghrib?.source === 'sunset') delete out.maghrib;
  return out;
}

/** What changed between two publishedIqamah() results, for the message. */
export function describeChanges(previous, current) {
  const changes = [];
  for (const key of Object.keys(NAMES)) {
    const from = previous[key], to = current[key];
    if (to && from !== to) changes.push(from ? `${NAMES[key]} ${to12h(to)} (was ${to12h(from)})` : `${NAMES[key]} ${to12h(to)}`);
  }
  return changes;
}

/**
 * `fcm`: {send(message)} (see fcm.mjs). `kv`: {get(key), put(key, value)}
 * for the last times seen per masjid. `allowHttp` lets plain-http masjid
 * addresses through, for local testing only.
 */
export function createRelay({ fcm, kv, fetchImpl = fetch, allowHttp = false, log = () => {} }) {
  async function fetchJson(url) {
    const res = await fetchImpl(url, { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(10_000) });
    if (!res.ok) throw new BadRequest(`${url} answered HTTP ${res.status}`);
    const text = await res.text();
    if (text.length > MAX_BODY) throw new BadRequest(`${url} sent too much`);
    try {
      return JSON.parse(text);
    } catch {
      throw new BadRequest(`${url} did not send JSON`);
    }
  }

  async function toTokens(tokens, notification, data) {
    let sent = 0;
    const invalid = [];
    for (const token of tokens) {
      const result = await fcm.send({
        token,
        notification,
        data,
        android: { priority: 'high', notification: { tag: data.type } },
        apns: { payload: { aps: { sound: 'default' } } },
      });
      if (result === 'sent') sent++;
      else invalid.push(token);
    }
    return { sent, invalid_tokens: invalid };
  }

  async function timesChanged(api) {
    const times = await fetchJson(`${api}/prayer-times`);
    let masjid = clean(times?.masjid?.name, 80);
    if (!masjid) masjid = clean((await fetchJson(`${api}/info`))?.masjid?.name, 80) || 'Your masjid';
    const current = publishedIqamah(times);
    if (!Object.keys(current).length) return { sent: 0, reason: 'no_times' };

    const topic = await timesTopic(api);
    const saved = await kv.get(topic);
    const previous = saved ? JSON.parse(saved) : null;
    const changes = describeChanges(previous ?? {}, current);
    if (previous && !changes.length) return { sent: 0, reason: 'unchanged' };

    const notification = previous
      ? { title: `${masjid}: iqamah times changed`, body: changes.join(', ') }
      : { title: `${masjid}: prayer times updated`, body: describeChanges({}, current).join(' · ') };
    await fcm.send({
      topic,
      notification,
      data: { type: 'times_changed', api },
      android: { notification: { tag: topic } },
      apns: { payload: { aps: { sound: 'default' } } },
    });
    await kv.put(topic, JSON.stringify(current));
    log(`times_changed ${api}: ${notification.body}`);
    return { sent: 1, invalid_tokens: [] };
  }

  async function notify(body) {
    const api = canonicalApi(body.api);
    if (!api || (!allowHttp && !api.startsWith('https://'))) throw new BadRequest('"api" must be the masjid’s https:// API address');
    if (body.event === 'times_changed') return timesChanged(api);

    const tokens = body.tokens;
    if (!Array.isArray(tokens) || tokens.length > MAX_TOKENS || !tokens.every((t) => typeof t === 'string' && t.length < 4096)) {
      throw new BadRequest(`"tokens" must be a list of at most ${MAX_TOKENS} push tokens`);
    }
    const masjid = clean(body.masjid, 80) || 'Snap Salat';
    if (body.event === 'approval_waiting') {
      const count = Math.max(1, Math.min(999, parseInt(body.count, 10) || 1));
      return toTokens(tokens, {
        title: masjid,
        body: count === 1 ? 'A volunteer is waiting for your approval.' : `${count} volunteers are waiting for your approval.`,
      }, { type: 'approval_waiting', api });
    }
    if (body.event === 'approved') {
      return toTokens(tokens, {
        title: masjid,
        body: 'You’ve been approved. You can now send prayer times from the app.',
      }, { type: 'approved', api });
    }
    throw new BadRequest('Unknown "event"');
  }

  return async function handle(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    if (request.method === 'GET' && path === '/') return json(200, { service: 'snap-salat-relay', version: 1 });
    if (path !== '/v1/notify') return fail(404, 'not_found', 'Not found');
    if (request.method !== 'POST') return fail(405, 'method_not_allowed', 'Use POST');
    const text = await request.text();
    if (text.length > MAX_BODY) return fail(413, 'too_large', 'Request too large');
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      return fail(400, 'invalid_json', 'Body must be JSON');
    }
    try {
      return json(200, await notify(body ?? {}));
    } catch (err) {
      if (err instanceof BadRequest) return fail(422, 'invalid', err.message);
      log(`error: ${err.message ?? err}`);
      return fail(502, 'upstream', 'Could not send the notification');
    }
  };
}
