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

export function apiRoutes({ store, dataDir, log, limits = {}, announce, push, track = (p) => p }) {
  const loginLimit = rateLimiter(limits.loginPerMinute ?? 10, 60_000);
  const registerLimit = rateLimiter(limits.registerPerHour ?? 5, 60 * 60_000);

  /**
   * The volunteer, or admin, the bearer token belongs to. Admins (the
   * accounts for the admin page) can sign in to the app too: they count as
   * approved, and may also approve volunteers.
   */
  function bearerUser(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    if (!m) return null;
    const hash = hashToken(m[1]);
    const user = store.sessionUser(hash);
    if (user) return { ...user, role: 'volunteer' };
    const admin = store.adminApiSession(hash);
    return admin && { id: null, adminId: admin.id, username: admin.username, name: admin.username, status: 'approved', role: 'admin' };
  }

  const userJson = (u) => ({ name: u.name, username: u.username, status: u.status, role: u.role });
  const volunteerJson = (u) => ({
    id: u.id, username: u.username, name: u.name, contact: u.contact, note: u.note,
    status: u.status, registered_at: u.created_at,
  });

  /** The signed-in admin, or null after answering 401/403. */
  function requireAdmin(req, res) {
    const user = bearerUser(req);
    if (!user) return fail(res, 401, 'unauthorized', 'Please sign in again.'), null;
    if (user.role !== 'admin') return fail(res, 403, 'forbidden', 'Only the masjid’s admins can do this.'), null;
    return user;
  }

  const background = (p) => track(p.catch((err) => log(`push error: ${err.message ?? err}`)));

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
    if (body.location !== undefined) {
      const { lat, lng } = body.location ?? {};
      if (!(typeof lat === 'number' && Math.abs(lat) <= 90 && typeof lng === 'number' && Math.abs(lng) <= 180)) {
        errors.location = 'must be {lat, lng} in degrees';
      }
    }
    if (!Object.keys(body.iqamah ?? {}).length && !Object.keys(body.adhan ?? {}).length) {
      errors.times = 'no times given';
    }
    return { errors, captured };
  }

  /** A message a volunteer can act on, for the most important problem. */
  function explain(errors, body, settings) {
    const ce = errors.captured_at;
    if (ce?.startsWith('is older')) {
      const maxAge = parseInt(settings.max_age_minutes, 10) || 1440;
      const taken = new Date(Date.parse(body.captured_at)).toLocaleString('en-US', {
        timeZone: settings.timezone, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      });
      const limit = maxAge % 60 === 0 ? `${maxAge / 60} hours` : `${maxAge} minutes`;
      return `This photo was taken ${taken}, more than ${limit} ago. Please take a new photo of the board.`;
    }
    if (ce === 'is in the future') return 'The photo’s time is in the future. Check the date and time on your phone.';
    const fields = Object.entries(errors).map(([k, v]) => `${k} ${v}`).join('; ');
    return `Some values were not accepted (${fields}).`;
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

  const setStatus = (status) => async (req, res, url, params) => {
    const admin = requireAdmin(req, res);
    if (!admin) return;
    const user = store.userById(Number(params.id));
    if (!user) return fail(res, 404, 'not_found', 'That volunteer no longer exists.');
    const was = user.status;
    store.setUserStatus(user.id, status, admin.username);
    log(`admin ${admin.username} (app): ${status} ${user.username}`);
    if (status === 'approved' && was !== 'approved' && push) background(push.approved(user.id));
    sendJson(res, 200, { volunteer: volunteerJson(store.userById(user.id)) });
  };

  const routes = {
    'GET /info': (req, res) => {
      const s = store.settings();
      sendJson(res, 200, {
        api: 'snap-salat',
        version: 1,
        masjid: { name: s.masjid_name, timezone: s.timezone },
        auth: { methods: ['password'], register: s.allow_registration === '1' },
        accepts: { prayers: IQAMAH_KEYS, adhan: true, image: s.accept_image === '1' },
        max_age_minutes: parseInt(s.max_age_minutes, 10) || 1440,
        ...(push?.info() ? { push: push.info() } : {}),
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
      // Admins sign in to the app with the same form, so their names are taken too.
      if (store.userByName(username) || store.adminByName(username)) {
        return fail(res, 409, 'username_taken', 'That username is already taken.');
      }
      store.createUser({
        username,
        name,
        contact: String(body.contact ?? '').slice(0, 120) || null,
        note: String(body.note ?? '').slice(0, 500) || null,
        passwordHash: await hashPassword(password),
      });
      log(`new volunteer registration: ${username} (${name})`);
      if (push) background(push.approvalWaiting());
      sendJson(res, 201, {
        status: 'pending',
        message: 'Thank you! The masjid will review your request. You can sign in now and check back.',
      });
    },

    'POST /auth/login': async (req, res) => {
      if (!loginLimit(clientIp(req))) return fail(res, 429, 'rate_limited', 'Too many attempts. Wait a minute.');
      const body = await readJson(req);
      const username = String(body.username ?? '').trim();
      const password = String(body.password ?? '');
      const { token, hash } = newToken();
      const expires = Date.now() + TOKEN_TTL_SECONDS * 1000;
      const reply = (user) => sendJson(res, 200, {
        access_token: token, token_type: 'Bearer', expires_in: TOKEN_TTL_SECONDS, user: userJson(user),
      });
      const admin = store.adminByName(username);
      if (admin && await checkPassword(password, admin.password_hash)) {
        store.addAdminApiSession(hash, admin.id, expires);
        log(`admin sign-in (app): ${admin.username}`);
        return reply({ name: admin.username, username: admin.username, status: 'approved', role: 'admin' });
      }
      const user = store.userByName(username);
      if (!user || !(await checkPassword(password, user.password_hash))) {
        return fail(res, 401, 'invalid_credentials', 'Wrong username or password.');
      }
      store.addSession(hash, user.id, expires);
      reply({ ...user, role: 'volunteer' });
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
      if (Object.keys(errors).length) {
        log(`rejected an update from ${user.username}: ${JSON.stringify(errors)}`);
        return fail(res, 422, 'invalid', explain(errors, body, settings), { fields: errors });
      }
      const current = store.current();
      const publishedBefore = JSON.stringify(publishedTimes(store).iqamah);
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
        location: body.location ? { lat: body.location.lat, lng: body.location.lng } : null,
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
      if (push && JSON.stringify(publishedTimes(store).iqamah) !== publishedBefore) background(push.timesChanged());
      sendJson(res, 201, { status: 'accepted', message: 'Prayer times updated. JazakAllahu khairan!' });
    },

    // --- admins, in the app
    'GET /volunteers': (req, res) => {
      if (!requireAdmin(req, res)) return;
      sendJson(res, 200, { volunteers: store.users().map(volunteerJson) });
    },

    // --- push notifications: this install's token, for whoever is signed in
    'POST /push/register': async (req, res) => {
      const user = bearerUser(req);
      if (!user) return fail(res, 401, 'unauthorized', 'Please sign in again.');
      const body = await readJson(req);
      const token = String(body.token ?? '');
      if (!/^[A-Za-z0-9:_\-]{20,4096}$/.test(token)) return fail(res, 422, 'invalid', 'Not a push token.', { fields: { token: 'invalid' } });
      store.addPushDevice(token, {
        userId: user.id,
        adminId: user.adminId ?? null,
        platform: ['android', 'ios'].includes(body.platform) ? body.platform : null,
      });
      sendJson(res, 200, { status: 'registered' });
    },
    'POST /push/unregister': async (req, res) => {
      const body = await readJson(req);
      // No sign-in needed: the token itself is the secret, and signing out
      // should stop notifications even when the session has already expired.
      store.removePushDevices([String(body.token ?? '')]);
      sendJson(res, 200, { status: 'unregistered' });
    },
  };

  const patterns = [
    [/^POST \/volunteers\/(?<id>\d+)\/approve$/, setStatus('approved')],
    [/^POST \/volunteers\/(?<id>\d+)\/revoke$/, setStatus('revoked')],
  ];

  return { routes, patterns };
}

export { HttpError };
