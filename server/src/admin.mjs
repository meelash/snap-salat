// The admin pages: approve volunteers, change settings, review updates.
// Server-rendered HTML forms; a cookie session with a CSRF token per form.

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { publishedTimes, sunsetMaghrib } from './times.mjs';
import { reviewNotes } from './review.mjs';
import { localDate } from './sun.mjs';
import { DEFAULT_SETTINGS } from './db.mjs';
import {
  sendHtml, redirect, readForm, cookies, escapeHtml as e, newToken, hashToken,
  checkPassword, rateLimiter, clientIp, HttpError,
} from './util.mjs';

const COOKIE = 'ss_admin';
const SESSION_MS = 12 * 60 * 60 * 1000;
const NAMES = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha', jumuah: "Jumu'ah" };
const ADHAN_NAMES = { fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' };

const to12h = (t) => {
  if (!t) return '—';
  const [h, m] = t.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};
const when = (iso, tz) => {
  if (!iso) return '—';
  try {
    return new Date(iso).toLocaleString('en-US', { timeZone: tz, dateStyle: 'medium', timeStyle: 'short' });
  } catch {
    return iso;
  }
};

const STYLE = `
:root { --bg:#0E2A21; --surface:#143629; --line:#2B5143; --brass:#D4AF5F; --text:#F1ECDF; --muted:#C3CFC7;
  --check:#F2B04A; --ok:#8FD3AE; --bad:#FF8A80; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
a { color: #E2C27A; } a:hover { color: #F3DCA4; }
header.top { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; padding: 16px 24px; border-bottom: 1px solid var(--line); }
header.top .brand { font-weight: 800; color: var(--brass); font-size: 20px; margin-right: auto; }
header.top nav { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
header.top nav a { text-decoration: none; padding: 8px 12px; border-radius: 999px; color: var(--text); }
header.top nav a.on { background: var(--surface); color: var(--brass); }
main { max-width: 980px; margin: 0 auto; padding: 24px; display: flex; flex-direction: column; gap: 24px; }
h1 { margin: 0; font-size: 26px; } h2 { margin: 0 0 12px; font-size: 13px; letter-spacing: 1.4px; text-transform: uppercase; color: var(--brass); }
.card { background: var(--surface); border-radius: 20px; padding: 20px; }
.muted { color: var(--muted); } .ok { color: var(--ok); } .warn { color: var(--check); } .bad { color: var(--bad); }
.times { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; }
.times div { background: var(--bg); border-radius: 14px; padding: 12px 14px; }
.times b { display: block; font-size: 24px; font-variant-numeric: tabular-nums; }
.times small { color: var(--muted); }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 10px 8px; border-top: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: 14px; border-top: none; }
.table-wrap { overflow-x: auto; }
form.inline { display: inline; }
button, .button { font: inherit; font-weight: 700; border-radius: 999px; padding: 9px 16px; border: 1px solid var(--line);
  background: transparent; color: var(--text); cursor: pointer; min-height: 40px; }
button.primary { background: var(--brass); color: #1A1A12; border-color: var(--brass); }
button.danger { color: var(--bad); border-color: #6B3A36; }
label { display: flex; flex-direction: column; gap: 6px; font-weight: 600; }
label.check { flex-direction: row; align-items: center; gap: 10px; font-weight: 500; }
input[type=text], input[type=password], input[type=number], select { font: inherit; color: var(--text); background: var(--bg);
  border: 1px solid #3C5E50; border-radius: 12px; padding: 10px 12px; min-height: 44px; }
input[type=checkbox], input[type=radio] { width: 20px; height: 20px; accent-color: var(--brass); }
.grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
.stack { display: flex; flex-direction: column; gap: 16px; }
.hint { font-weight: 400; font-size: 14px; color: var(--muted); }
.notice { background: #1E4436; border: 1px solid var(--line); border-radius: 14px; padding: 12px 16px; }
pre { background: var(--bg); padding: 14px; border-radius: 12px; overflow-x: auto; font-size: 14px; color: var(--text); white-space: pre-wrap; word-break: break-all; }
img.photo { max-width: 100%; border-radius: 14px; }
.login { max-width: 380px; margin: 10vh auto; }
.notes { display: flex; flex-direction: column; gap: 4px; margin-top: 6px; font-size: 14px; }
@media (max-width: 640px) {
  main { padding: 16px; }
  table.users, table.users tbody, table.users tr, table.users td { display: block; }
  table.users th, table.users tr:first-child { display: none; }
  table.users tr { border-top: 1px solid var(--line); padding: 12px 0; }
  table.users td { border: none; padding: 3px 0; }
}
`;

function page(title, body, { session, active } = {}) {
  const nav = session
    ? `<nav>
        ${[['/admin', 'Overview'], ['/admin/settings', 'Settings'], ['/admin/history', 'History'], ['/admin/embed', 'Website widget']]
          .map(([href, label]) => `<a href="${href}"${active === href ? ' class="on" aria-current="page"' : ''}>${label}</a>`).join('')}
        <form class="inline" method="post" action="/admin/logout"><input type="hidden" name="_csrf" value="${e(session.csrf)}">
          <button type="submit">Sign out</button></form>
      </nav>`
    : '';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${e(title)} · Snap Salat admin</title><style>${STYLE}</style></head>
<body><header class="top"><div class="brand">Snap Salat</div>${nav}</header><main>${body}</main></body></html>`;
}

export function adminRoutes({ store, dataDir, secureCookies, log, announce }) {
  const loginLimit = rateLimiter(10, 15 * 60_000);

  function session(req) {
    const token = cookies(req)[COOKIE];
    return token ? store.adminSession(hashToken(token)) : null;
  }

  /** Requires a signed-in admin; for POSTs also a matching CSRF token. */
  async function guard(req, res) {
    const s = session(req);
    if (!s) {
      redirect(res, '/admin/login');
      return null;
    }
    if (req.method === 'POST') {
      const form = await readForm(req);
      const a = Buffer.from(String(form._csrf ?? '')), b = Buffer.from(s.csrf);
      if (a.length !== b.length || !timingSafeEqual(a, b)) throw new HttpError(403, 'csrf', 'Form expired. Go back and try again.');
      return { session: s, form };
    }
    return { session: s };
  }

  // The public address, as the browser reached us (through the proxy).
  const origin = (req) =>
    `${req.headers['x-forwarded-proto'] ?? (secureCookies ? 'https' : 'http')}://${req.headers.host}`;

  /** Review flags (amber) and notes (muted) for an update. */
  const notesHtml = (notes, compact = false) => {
    const shown = compact ? notes.filter((n) => n.level !== 'note') : notes;
    if (!shown.length) return '';
    return `<div class="notes">${shown.map((n) => `<div class="${n.level === 'flag' ? 'warn' : n.level === 'ok' ? 'ok' : 'muted'}">${
      n.level === 'flag' ? '⚑ ' : ''}${e(n.text)}</div>`).join('')}</div>`;
  };

  const csrfField = (s) => `<input type="hidden" name="_csrf" value="${e(s.csrf)}">`;

  function overview(s, notice, req, recent = [], statuses = new Map()) {
    const settings = store.settings();
    const tz = settings.timezone;
    const pub = publishedTimes(store);
    const current = store.current();
    const last = current?.submission_id ? store.submission(current.submission_id) : null;
    const users = store.users();
    const byStatus = (st) => users.filter((u) => u.status === st);

    const userRow = (u, actions) => `<tr>
      <td><b>${e(u.name)}</b><br><span class="muted">${e(u.username)}</span></td>
      <td>${e(u.contact ?? '')}${u.note ? `<br><span class="muted">${e(u.note)}</span>` : ''}</td>
      <td class="muted">${e(when(u.created_at, tz))}</td>
      <td>${actions.map(([action, label, cls]) => `<form class="inline" method="post" action="/admin/users/${u.id}/${action}">
        ${csrfField(s)}<button type="submit" class="${cls ?? ''}">${label}</button></form>`).join(' ')}</td>
    </tr>`;
    const userTable = (list, actions, empty) => list.length
      ? `<div class="table-wrap"><table class="users"><tr><th>Volunteer</th><th>Contact / note</th><th>Registered</th><th></th></tr>
         ${list.map((u) => userRow(u, actions)).join('')}</table></div>`
      : `<p class="muted">${empty}</p>`;

    const maghribNote = pub.maghrib.source === 'sunset'
      ? `Sunset ${to12h(pub.maghrib.sunset)} + ${pub.maghrib.offset_minutes} min`
      : 'From the board';

    return page('Overview', `
      ${notice ? `<div class="notice">${e(notice)}</div>` : ''}
      <h1>${e(settings.masjid_name)}</h1>
      <section class="card">
        <h2>Published today · ${e(pub.date)}</h2>
        <div class="times">
          ${Object.entries(NAMES).map(([k, n]) => `<div><small>${n}</small><b>${to12h(pub.iqamah[k])}</b>
            ${k === 'maghrib' ? `<small>${e(maghribNote)}</small>` : ''}</div>`).join('')}
        </div>
        ${Object.keys(pub.adhan).length ? `<p class="muted">Adhan: ${Object.entries(ADHAN_NAMES)
          .filter(([k]) => pub.adhan[k]).map(([k, n]) => `${n} ${to12h(pub.adhan[k])}`).join(' · ')}</p>` : ''}
        ${last ? `<p class="muted">Last updated by <b>${e(last.user_name ?? 'unknown')}</b> from a photo taken
            ${e(when(last.captured_at, tz))} (${e(last.captured_at_source ?? '?')})${last.display_clock
              ? `; the board clock showed ${to12h(last.display_clock)}` : ''}.
            ${last.photo_file ? `<a href="/admin/photos/${e(last.photo_file)}">See the photo</a>.` : ''}</p>
          ${notesHtml(reviewNotes(last, settings))}`
          : '<p class="muted">No updates yet. Approve a volunteer below, then send times from the app.</p>'}
      </section>
      <section class="card">
        <h2>Waiting for approval</h2>
        ${userTable(byStatus('pending'), [['approve', 'Approve', 'primary'], ['revoke', 'Decline', 'danger']],
          settings.allow_registration === '1' ? 'No one is waiting.' : 'No one is waiting. Sign-ups from the app are turned off in Settings.')}
      </section>
      <section class="card">
        <h2>Can update the times</h2>
        ${userTable(byStatus('approved'), [['revoke', 'Revoke', 'danger']], 'No approved volunteers yet.')}
      </section>
      ${store.settings().announce_enabled === '1' || recent.length ? `<section class="card">
        <h2>Announcements</h2>
        ${recent.length ? `<div class="table-wrap"><table class="users"><tr><th>Drafted</th><th>Changes</th><th>Status</th><th></th></tr>
          ${recent.map((a) => `<tr>
            <td>${e(when(a.created_at, tz))}<br><span class="muted">effective ${e(a.effective_date)}</span></td>
            <td>${a.changes.map((c) => `${NAMES[c.key]} ${to12h(c.from)} → <b>${to12h(c.to)}</b>`).join('<br>')}</td>
            <td>${a.status === 'failed' ? `<span class="bad">Failed</span><br><span class="muted">${e(a.error ?? '')}</span>`
              : a.status === 'sending' ? '<span class="muted">Sending…</span>'
              : `<span class="ok">${e((statuses.get(a.id) ?? 'drafted').replaceAll('_', ' '))}</span>${a.remote_id ? `<br><span class="muted">post ${e(a.remote_id)}</span>` : ''}`}</td>
            <td>${a.status === 'failed' ? `<form class="inline" method="post" action="/admin/announcements/${a.id}/retry">
              ${csrfField(s)}<button type="submit">Retry</button></form>` : ''}</td>
          </tr>`).join('')}</table></div>`
          : '<p class="muted">Nothing announced yet. A post is drafted the next time a photo changes a time.</p>'}
      </section>` : ''}
      ${byStatus('revoked').length ? `<section class="card"><h2>Revoked or declined</h2>
        ${userTable(byStatus('revoked'), [['approve', 'Approve'], ['delete', 'Delete', 'danger']], '')}</section>` : ''}
      <p class="muted">Volunteers connect in the app with <b>Enter address</b> →
        <code>${e(`${origin(req)}/snap-salat`)}</code>, then register.</p>
    `, { session: s, active: '/admin' });
  }

  function settingsPage(s, notice, errors = {}) {
    const st = store.settings();
    const sunsetNow = st.maghrib_mode === 'sunset' ? sunsetMaghrib(st, localDate(Date.now(), st.timezone)) : null;
    const zones = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [];
    const err = (k) => (errors[k] ? `<span class="bad">${e(errors[k])}</span>` : '');
    const checked = (k) => (st[k] === '1' ? ' checked' : '');
    const sel = (k, v) => (st[k] === v ? ' selected' : '');
    return page('Settings', `
      ${notice ? `<div class="notice">${e(notice)}</div>` : ''}
      <h1>Settings</h1>
      <form method="post" action="/admin/settings" class="stack">
        ${csrfField(s)}
        <section class="card stack">
          <h2>Masjid</h2>
          <div class="grid2">
            <label>Name <input type="text" name="masjid_name" value="${e(st.masjid_name)}" required maxlength="120"></label>
            <label>Time zone ${err('timezone')}
              <input type="text" name="timezone" value="${e(st.timezone)}" list="zones" required>
              <datalist id="zones">${zones.map((z) => `<option value="${e(z)}">`).join('')}</datalist>
              <span class="hint">e.g. America/New_York</span></label>
            <label>Latitude ${err('latitude')}<input type="text" inputmode="decimal" name="latitude" value="${e(st.latitude)}" placeholder="41.3962"></label>
            <label>Longitude ${err('longitude')}<input type="text" inputmode="decimal" name="longitude" value="${e(st.longitude)}" placeholder="-72.8973"></label>
          </div>
          <span class="hint">Latitude and longitude are only needed for Maghrib at sunset. Find them by long-pressing the masjid in a maps app.</span>
        </section>

        <section class="card stack">
          <h2>Maghrib</h2>
          <label class="check"><input type="radio" name="maghrib_mode" value="board"${st.maghrib_mode === 'board' ? ' checked' : ''}>
            Use the time on the board (from the app)</label>
          <label class="check"><input type="radio" name="maghrib_mode" value="sunset"${st.maghrib_mode === 'sunset' ? ' checked' : ''}>
            Calculate from today’s sunset (the board’s Maghrib clock is ignored)</label>
          <div class="grid2">
            <label>Minutes after sunset
              <select name="maghrib_offset">${[0, 3, 5, 7, 10, 15, 20].map((m) => `<option value="${m}"${sel('maghrib_offset', String(m))}>${m === 0 ? 'At sunset' : `${m} minutes`}</option>`).join('')}</select></label>
            <label class="check" style="align-self:end"><input type="checkbox" name="maghrib_round" value="up5"${st.maghrib_round === 'up5' ? ' checked' : ''}>
              Round up to the next 5 minutes</label>
          </div>
          ${err('maghrib')}
          ${sunsetNow ? `<p class="muted">Today: sunset ${to12h(sunsetNow.sunset)}, so Maghrib is <b>${to12h(sunsetNow.time)}</b>.</p>` : ''}
        </section>

        <section class="card stack">
          <h2>Volunteers and photos</h2>
          <label class="check"><input type="checkbox" name="allow_registration" value="1"${checked('allow_registration')}>
            Let volunteers sign up from the app (you still approve each one)</label>
          <label class="check"><input type="checkbox" name="accept_image" value="1"${checked('accept_image')}>
            Ask the app to upload each photo, so you can check updates</label>
          <label>Reject photos older than (minutes) ${err('max_age_minutes')}
            <input type="number" name="max_age_minutes" min="10" max="10080" value="${e(st.max_age_minutes)}"></label>
          <div class="grid2">
            <label>Flag photos taken farther than (metres) ${err('flag_distance_m')}
              <input type="number" name="flag_distance_m" min="50" max="100000" value="${e(st.flag_distance_m)}">
              <span class="hint">From the masjid’s location above, using the photo’s own GPS data.</span></label>
            <label>Flag when the board’s clock is off by more than (minutes) ${err('flag_clock_minutes')}
              <input type="number" name="flag_clock_minutes" min="1" max="180" value="${e(st.flag_clock_minutes)}">
              <span class="hint">Compared with when the photo was taken.</span></label>
          </div>
        </section>

        <section class="card stack">
          <h2>Website widget</h2>
          <div class="grid2">
            <label>Theme <select name="widget_theme"><option value="dark"${sel('widget_theme', 'dark')}>Dark green</option>
              <option value="light"${sel('widget_theme', 'light')}>Light</option></select></label>
            <label>Accent colour ${err('widget_accent')}<input type="text" name="widget_accent" value="${e(st.widget_accent)}" pattern="#[0-9A-Fa-f]{6}"></label>
          </div>
          <label class="check"><input type="checkbox" name="widget_show_adhan" value="1"${checked('widget_show_adhan')}>
            Also show adhan (start) times when the board has them</label>
        </section>

        <section class="card stack">
          <h2>Announcements</h2>
          <p class="muted">When a volunteer’s photo changes an iqamah time, draft a “prayer times” post in your
            announcement list. Only real changes are announced, and never from a photo older than the last
            announcement’s.</p>
          <label class="check"><input type="checkbox" name="announce_enabled" value="1"${checked('announce_enabled')}>
            Draft an announcement when the times change</label>
          <div class="grid2">
            <label>Announcement list address ${err('announce_url')}
              <input type="text" name="announce_url" value="${e(st.announce_url)}" placeholder="http://localhost:3000">
              <span class="hint">Its API is at /api/v1 under this address.</span></label>
            <label>API key ${err('announce_token')}
              <input type="password" name="announce_token" value="" autocomplete="off"
                placeholder="${st.announce_token ? 'Saved. Leave blank to keep it' : 'bb_…'}"></label>
          </div>
          <label class="check"><input type="checkbox" name="announce_submit" value="1"${checked('announce_submit')}>
            Submit each draft for approval (otherwise it stays a draft)</label>
          <div><button type="submit" name="_action" value="test">Save and test connection</button></div>
        </section>
        <div><button type="submit" class="primary">Save settings</button></div>
      </form>
    `, { session: s, active: '/admin/settings' });
  }

  function validateSettings(form) {
    const v = {}, errors = {};
    v.masjid_name = String(form.masjid_name ?? '').trim().slice(0, 120) || DEFAULT_SETTINGS.masjid_name;
    v.timezone = String(form.timezone ?? '').trim();
    try {
      new Intl.DateTimeFormat('en', { timeZone: v.timezone });
    } catch {
      errors.timezone = 'Unknown time zone';
    }
    for (const [k, lo, hi] of [['latitude', -90, 90], ['longitude', -180, 180]]) {
      const raw = String(form[k] ?? '').trim();
      if (raw === '') v[k] = '';
      else if (!Number.isFinite(Number(raw)) || Number(raw) < lo || Number(raw) > hi) errors[k] = `Must be between ${lo} and ${hi}`;
      else v[k] = raw;
    }
    v.maghrib_mode = form.maghrib_mode === 'sunset' ? 'sunset' : 'board';
    v.maghrib_offset = String(Math.max(0, Math.min(60, parseInt(form.maghrib_offset, 10) || 0)));
    v.maghrib_round = form.maghrib_round === 'up5' ? 'up5' : 'none';
    if (v.maghrib_mode === 'sunset' && (v.latitude === '' || v.longitude === '')) {
      errors.maghrib = 'To calculate Maghrib from sunset, enter the masjid’s latitude and longitude above.';
    }
    v.allow_registration = form.allow_registration === '1' ? '1' : '0';
    v.accept_image = form.accept_image === '1' ? '1' : '0';
    const age = parseInt(form.max_age_minutes, 10);
    if (!(age >= 10 && age <= 10080)) errors.max_age_minutes = 'Between 10 and 10080';
    else v.max_age_minutes = String(age);
    for (const [k, lo, hi] of [['flag_distance_m', 50, 100000], ['flag_clock_minutes', 1, 180]]) {
      const n = parseInt(form[k], 10);
      if (form[k] === undefined) continue;
      if (!(n >= lo && n <= hi)) errors[k] = `Between ${lo} and ${hi}`;
      else v[k] = String(n);
    }
    v.widget_theme = form.widget_theme === 'light' ? 'light' : 'dark';
    if (!/^#[0-9a-f]{6}$/i.test(form.widget_accent ?? '')) errors.widget_accent = 'A colour like #D4AF5F';
    else v.widget_accent = form.widget_accent;
    v.widget_show_adhan = form.widget_show_adhan === '1' ? '1' : '0';
    v.announce_enabled = form.announce_enabled === '1' ? '1' : '0';
    v.announce_submit = form.announce_submit === '1' ? '1' : '0';
    const announceUrl = String(form.announce_url ?? '').trim();
    if (announceUrl && !/^https?:\/\/[^\s/]+/.test(announceUrl)) errors.announce_url = 'A web address like http://localhost:3000';
    else v.announce_url = announceUrl;
    // The token is never sent back to the page; blank means "keep it".
    const token = String(form.announce_token ?? '').trim();
    if (token && !/^bb_[A-Za-z0-9_-]+$/.test(token)) errors.announce_token = 'API keys start with bb_';
    else if (token) v.announce_token = token;
    if (v.announce_enabled === '1' && (!announceUrl || !(token || store.settings().announce_token))) {
      errors.announce_url = errors.announce_url ?? 'Enter the address and token to turn announcements on.';
    }
    return { values: v, errors };
  }

  function historyPage(s) {
    const settings = store.settings();
    const tz = settings.timezone;
    const rows = store.submissions(100).map((x) => `<tr>
      <td>${e(when(x.received_at, tz))}</td>
      <td>${e(x.user_name ?? '—')}</td>
      <td>${e(when(x.captured_at, tz))}<br><span class="muted">${e(x.captured_at_source ?? '')}${x.display_clock ? ` · board clock ${to12h(x.display_clock)}` : ''}</span></td>
      <td>${Object.entries(NAMES).filter(([k]) => x.iqamah[k]).map(([k, n]) => `${n} ${to12h(x.iqamah[k])}`).join('<br>')}</td>
      <td>${x.recognition?.edited?.length ? `<span class="warn">Corrected: ${e(x.recognition.edited.join(', '))}</span>` : '<span class="muted">As read</span>'}
        ${notesHtml(reviewNotes(x, settings), true)}</td>
      <td>${x.photo_file ? `<a href="/admin/photos/${e(x.photo_file)}">Photo</a>` : '<span class="muted">—</span>'}</td>
    </tr>`).join('');
    return page('History', `<h1>History</h1><section class="card"><div class="table-wrap">
      ${rows ? `<table><tr><th>Received</th><th>By</th><th>Photo taken</th><th>Iqamah</th><th>Checks</th><th></th></tr>${rows}</table>`
        : '<p class="muted">No updates yet.</p>'}</div></section>`, { session: s, active: '/admin/history' });
  }

  function embedPage(s, req) {
    const snippet = `<script src="${origin(req)}/widget.js" async></script>`;
    const iframe = `<iframe src="${origin(req)}/widget" title="Prayer times" style="border:0;width:100%;max-width:420px;height:560px"></iframe>`;
    return page('Website widget', `<h1>Website widget</h1>
      <section class="card stack"><h2>Add it to your website</h2>
        <p>Paste this where the prayer times should appear. It sizes itself and updates every few minutes.</p>
        <pre>${e(snippet)}</pre>
        <p class="muted">Options: <code>data-theme="light"</code>, <code>data-accent="#1E3A8A"</code>,
          <code>data-adhan="1"</code>, <code>data-target="#prayer-times"</code> (render inside an existing element).</p>
        <p>Or, where scripts aren’t allowed, an iframe:</p><pre>${e(iframe)}</pre>
        <p>Raw data for your own design: <a href="/prayer-times.json">/prayer-times.json</a> (open to any website).</p>
      </section>
      <section class="card"><h2>Preview</h2>${snippet.replace(' async', '')}</section>`, { session: s, active: '/admin/embed' });
  }

  const userAction = (status) => async (req, res, url, params) => {
    const g = await guard(req, res);
    if (!g) return;
    const user = store.userById(Number(params.id));
    if (user) {
      if (status === 'delete') store.deleteUser(user.id);
      else store.setUserStatus(user.id, status, g.session.username);
      log(`admin ${g.session.username}: ${status} ${user.username}`);
    }
    redirect(res, '/admin');
  };

  return {
    exact: {
      'GET /admin/login': (req, res) => {
        const first = !store.hasAdmins();
        sendHtml(res, 200, page('Sign in', `<section class="card login stack">
          <h1>Admin sign in</h1>
          ${first ? '<p class="warn">No admin account yet. On the server run:<br><code>node server/server.mjs create-admin &lt;username&gt;</code></p>' : ''}
          <form method="post" action="/admin/login" class="stack">
            <label>Username <input type="text" name="username" autocomplete="username" required></label>
            <label>Password <input type="password" name="password" autocomplete="current-password" required></label>
            <button type="submit" class="primary">Sign in</button>
          </form></section>`));
      },
      'POST /admin/login': async (req, res) => {
        const form = await readForm(req);
        const fail = (msg) => sendHtml(res, 401, page('Sign in', `<section class="card login stack"><h1>Admin sign in</h1>
          <p class="bad">${e(msg)}</p><a href="/admin/login">Try again</a></section>`));
        if (!loginLimit(clientIp(req))) return fail('Too many attempts. Wait 15 minutes.');
        const admin = store.adminByName(String(form.username ?? '').trim());
        if (!admin || !(await checkPassword(String(form.password ?? ''), admin.password_hash))) return fail('Wrong username or password.');
        const { token, hash } = newToken();
        store.addAdminSession(hash, admin.id, newToken().token, Date.now() + SESSION_MS);
        log(`admin sign-in: ${admin.username}`);
        redirect(res, '/admin', {
          'Set-Cookie': `${COOKIE}=${token}; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=${SESSION_MS / 1000}${secureCookies ? '; Secure' : ''}`,
        });
      },
      'POST /admin/logout': async (req, res) => {
        const g = await guard(req, res);
        if (!g) return;
        store.deleteAdminSession(hashToken(cookies(req)[COOKIE]));
        redirect(res, '/admin/login', { 'Set-Cookie': `${COOKIE}=; Path=/admin; HttpOnly; SameSite=Strict; Max-Age=0` });
      },
      'GET /admin': async (req, res, url) => {
        const g = await guard(req, res);
        if (!g) return;
        // Live status of recent announcements (draft → … → sent).
        const recent = store.announcements(5);
        const statuses = new Map(await Promise.all(recent
          .filter((a) => a.remote_id)
          .map(async (a) => [a.id, await announce.remoteStatus(a.remote_id)])));
        const notice = url.searchParams.get('saved') ? 'Saved.' : url.searchParams.get('retried') ? 'Tried again.' : null;
        sendHtml(res, 200, overview(g.session, notice, req, recent, statuses));
      },
      'GET /admin/settings': async (req, res, url) => {
        const g = await guard(req, res);
        if (g) sendHtml(res, 200, settingsPage(g.session, url.searchParams.get('saved') ? 'Settings saved.' : null));
      },
      'POST /admin/settings': async (req, res) => {
        const g = await guard(req, res);
        if (!g) return;
        const { values, errors } = validateSettings(g.form);
        if (Object.keys(errors).length) {
          return sendHtml(res, 422, settingsPage(g.session, 'Some settings need fixing.', errors));
        }
        store.saveSettings(values);
        log(`admin ${g.session.username}: settings saved`);
        if (g.form._action === 'test') {
          const result = await announce.test();
          return sendHtml(res, 200, settingsPage(g.session, `Settings saved. ${result.message}`));
        }
        redirect(res, '/admin/settings?saved=1');
      },
      'GET /admin/history': async (req, res) => {
        const g = await guard(req, res);
        if (g) sendHtml(res, 200, historyPage(g.session));
      },
      'GET /admin/embed': async (req, res) => {
        const g = await guard(req, res);
        if (g) sendHtml(res, 200, embedPage(g.session, req));
      },
    },
    patterns: [
      [/^POST \/admin\/announcements\/(?<id>\d+)\/retry$/, async (req, res, url, params) => {
        const g = await guard(req, res);
        if (!g) return;
        const a = store.announcement(Number(params.id));
        if (a && a.status === 'failed') await announce.retry(a.id);
        redirect(res, '/admin?retried=1');
      }],
      [/^POST \/admin\/users\/(?<id>\d+)\/approve$/, userAction('approved')],
      [/^POST \/admin\/users\/(?<id>\d+)\/revoke$/, userAction('revoked')],
      [/^POST \/admin\/users\/(?<id>\d+)\/delete$/, userAction('delete')],
      [/^GET \/admin\/photos\/(?<file>[0-9a-f]{64}\.jpg)$/, async (req, res, url, params) => {
        const g = await guard(req, res);
        if (!g) return;
        const path = join(dataDir, 'photos', params.file);
        if (!existsSync(path)) throw new HttpError(404, 'not_found', 'Not found');
        res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=86400' });
        res.end(readFileSync(path));
      }],
    ],
  };
}
