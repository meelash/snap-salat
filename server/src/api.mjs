// The Snap Salat API, version 1 (docs/api.md), mounted at /snap-salat.

import { createHash } from 'node:crypto';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { publishedTimes, IQAMAH_KEYS, ADHAN_KEYS } from './times.mjs';
import { localDate } from './sun.mjs';
import {
  sendJson, fail, readJson, newToken, hashToken, hashPassword, checkPassword,
  rateLimiter, clientIp, HttpError,
} from './util.mjs';

const TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60;
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
const USERNAME = /^[A-Za-z0-9_.-]{3,40}$/;

export function apiRoutes({ store, dataDir, log, limits = {}, announce, track = (p) => p }) {
  const loginLimit = rateLimiter(limits.loginPerMinute ?? 10, 60_000);
  const registerLimit = rateLimiter(limits.registerPerHour ?? 5, 60 * 60_000);

  function bearerUser(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    return m ? store.sessionUser(hashToken(m[1])) : null;
  }

  const userJson = (u) => ({ name: u.name, username: u.username, status: u.status });

  function validateSubmission(body, settings) {
    const errors = {};
    const captured = Date.parse(body.captured_at);
    const maxAge = parseInt(settings.max_age_minutes, 10) || 1440;
    if (typeof body.captured_at !== 'string' || Number.isNaN(captured)) {
      errors.captured_at = 'must be an ISO 8601 date-time';
    } else if (captured > Date.now() + 5 * 60_000) {
      errors.captured_at = 'is in the future';
    } else if (captured < Date.now() - maxAge * 60_000) {
      errors.captured_at = `is older than ${maxAge} minutes`;
    }
    if (body.date !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(body.date)) errors.date = 'must be YYYY-MM-DD';
    for (const [name, allowed] of [['iqamah', IQAMAH_KEYS], ['adhan', ADHAN_KEYS]]) {
      const v = body[name] ?? {};
      if (typeof v !== 'object' || Array.isArray(v)) {
        errors[name] = 'must be an object';
        continue;
      }
      for (const [k, t] of Object.entries(v)) {
        if (!allowed.includes(k)) errors[`${name}.${k}`] = 'unknown prayer';
        else if (!HHMM.test(t)) errors[`${name}.${k}`] = 'must be HH:MM (24-hour)';
      }
    }
    if (!Object.keys(body.iqamah ?? {}).length && !Object.keys(body.adhan ?? {}).length) {
      errors.times = 'no times given';
    }
    return { errors, captured };
  }

  function savePhoto(base64) {
    const bytes = Buffer.from(String(base64), 'base64');
    if (bytes.length < 4 || bytes.length > 8 * 1024 * 1024 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
    const sha = createHash('sha256').update(bytes).digest('hex');
    const dir = join(dataDir, 'photos');
    mkdirSync(dir, { recursive: true });
    const file = `${sha}.jpg`;
    writeFileSync(join(dir, file), bytes);
    return { file, sha };
  }

  return {
    'GET /info': (req, res) => {
      const s = store.settings();
      sendJson(res, 200, {
        api: 'snap-salat',
        version: 1,
        masjid: { name: s.masjid_name, timezone: s.timezone },
        auth: { methods: ['password'], register: s.allow_registration === '1' },
        accepts: { prayers: IQAMAH_KEYS, adhan: true, image: s.accept_image === '1' },
        max_age_minutes: parseInt(s.max_age_minutes, 10) || 1440,
      });
    },

    'POST /auth/register': async (req, res) => {
      if (store.settings().allow_registration !== '1') {
        return fail(res, 403, 'registration_closed', 'This masjid isn’t accepting new volunteers in the app. Please ask the masjid for an account.');
      }
      if (!registerLimit(clientIp(req))) return fail(res, 429, 'rate_limited', 'Too many sign-ups from here. Try again later.');
      const body = await readJson(req);
      const username = String(body.username ?? '').trim();
      const name = String(body.name ?? '').trim();
      const password = String(body.password ?? '');
      const fields = {};
      if (!USERNAME.test(username)) fields.username = '3–40 letters, digits, dot, dash or underscore';
      if (password.length < 8) fields.password = 'at least 8 characters';
      if (!name || name.length > 80) fields.name = 'your name, up to 80 characters';
      if (Object.keys(fields).length) return fail(res, 422, 'invalid', 'Please check the highlighted fields.', { fields });
      if (store.userByName(username)) return fail(res, 409, 'username_taken', 'That username is already taken.');
      store.createUser({
        username,
        name,
        contact: String(body.contact ?? '').slice(0, 120) || null,
        note: String(body.note ?? '').slice(0, 500) || null,
        passwordHash: await hashPassword(password),
      });
      log(`new volunteer registration: ${username} (${name})`);
      sendJson(res, 201, {
        status: 'pending',
        message: 'Thank you! The masjid will review your request. You can sign in now and check back.',
      });
    },

    'POST /auth/login': async (req, res) => {
      if (!loginLimit(clientIp(req))) return fail(res, 429, 'rate_limited', 'Too many attempts. Wait a minute.');
      const body = await readJson(req);
      const user = store.userByName(String(body.username ?? '').trim());
      const ok = user ? await checkPassword(String(body.password ?? ''), user.password_hash) : false;
      if (!ok) return fail(res, 401, 'invalid_credentials', 'Wrong username or password.');
      const { token, hash } = newToken();
      store.addSession(hash, user.id, Date.now() + TOKEN_TTL_SECONDS * 1000);
      sendJson(res, 200, { access_token: token, token_type: 'Bearer', expires_in: TOKEN_TTL_SECONDS, user: userJson(user) });
    },

    'GET /auth/check': (req, res) => {
      const user = bearerUser(req);
      if (!user) return fail(res, 401, 'unauthorized', 'Please sign in again.');
      sendJson(res, 200, { user: userJson(user) });
    },

    'GET /prayer-times': (req, res) => {
      sendJson(res, 200, publishedTimes(store), { 'Access-Control-Allow-Origin': '*' });
    },

    'POST /prayer-times': async (req, res) => {
      const user = bearerUser(req);
      if (!user) return fail(res, 401, 'unauthorized', 'Please sign in again.');
      if (user.status !== 'approved') {
        return fail(res, 403, 'not_approved', user.status === 'pending'
          ? 'Your account is waiting for the masjid to approve it.'
          : 'Your permission to update the times has been removed.');
      }
      const settings = store.settings();
      const body = await readJson(req, 15 * 1024 * 1024);
      const { errors, captured } = validateSubmission(body, settings);
      if (Object.keys(errors).length) return fail(res, 422, 'invalid', 'Some values were not accepted.', { fields: errors });
      const current = store.current();
      if (current?.captured_at_ms != null && current.captured_at_ms >= captured) {
        return fail(res, 409, 'stale', `Times from a newer photo (taken ${current.captured_at}) are already saved.`);
      }
      let photo = null;
      if (settings.accept_image === '1' && body.image?.jpeg_base64) photo = savePhoto(body.image.jpeg_base64);
      const previous = current?.iqamah ?? {};
      const submissionId = store.addSubmission({
        userId: user.id,
        userName: user.name,
        capturedAt: body.captured_at,
        capturedAtMs: captured,
        capturedAtSource: body.captured_at_source,
        date: body.date,
        iqamah: body.iqamah ?? {},
        adhan: body.adhan ?? {},
        displayClock: HHMM.test(body.display_clock ?? '') ? body.display_clock : null,
        recognition: body.recognition,
        client: body.client,
        imageSha256: photo?.sha ?? body.image?.sha256 ?? null,
        photoFile: photo?.file ?? null,
      });
      log(`${user.username} updated times from a photo taken ${body.captured_at}`);
      // Draft an announcement if the times changed; in the background, so
      // the announcement list being slow or down never affects the app.
      if (announce) {
        track(announce.afterSubmission({
          submissionId,
          capturedAtMs: captured,
          effectiveDate: body.date ?? localDate(captured, settings.timezone),
          previous,
          incoming: body.iqamah ?? {},
          merged: store.current().iqamah,
        }).catch((err) => log(`announcement error: ${err.message ?? err}`)));
      }
      sendJson(res, 201, { status: 'accepted', message: 'Prayer times updated. JazakAllahu khairan!' });
    },
  };
}

export { HttpError };
