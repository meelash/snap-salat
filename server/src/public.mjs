// Public outputs: JSON, and an embeddable widget for the masjid's website.

import { publishedTimes } from './times.mjs';
import { zonedParts } from './sun.mjs';
import { sendJson, sendHtml, escapeHtml } from './util.mjs';

const NAMES = {
  fajr: ['Fajr', 'فجر'],
  dhuhr: ['Dhuhr', 'ظهر'],
  asr: ['Asr', 'عصر'],
  maghrib: ['Maghrib', 'مغرب'],
  isha: ['Isha', 'عشاء'],
  jumuah: ["Jumu'ah", 'جمعة'],
};
const ADHAN_NAMES = { ...NAMES, sunrise: ['Sunrise', 'شروق'] };

const THEMES = {
  dark: { bg: '#0E2A21', surface: '#143629', text: '#F1ECDF', muted: '#C3CFC7', line: '#2B5143' },
  light: { bg: '#FBF8F1', surface: '#FFFFFF', text: '#1B1A17', muted: '#5E5A50', line: '#E6DDC8' },
};

/** Mixes a #rrggbb colour towards black by `amount` (0..1). */
function darken(hex, amount) {
  const n = parseInt(hex.slice(1), 16);
  const ch = (shift) => Math.round(((n >> shift) & 255) * (1 - amount));
  return `#${[16, 8, 0].map((s) => ch(s).toString(16).padStart(2, '0')).join('')}`;
}

function to12h(t) {
  const [h, m] = t.split(':').map(Number);
  return { time: `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')}`, ampm: h < 12 ? 'AM' : 'PM' };
}

/** Options from the query string, falling back to the admin's settings. */
function widgetOptions(url, settings) {
  const q = url.searchParams;
  const theme = THEMES[q.get('theme')] ? q.get('theme') : settings.widget_theme in THEMES ? settings.widget_theme : 'dark';
  const accentParam = q.get('accent');
  const accent = /^#?[0-9a-f]{6}$/i.test(accentParam ?? '')
    ? `#${accentParam.replace('#', '')}`
    : /^#[0-9a-f]{6}$/i.test(settings.widget_accent) ? settings.widget_accent : '#D4AF5F';
  const showAdhan = q.has('adhan') ? q.get('adhan') === '1' : settings.widget_show_adhan === '1';
  return { theme, accent, showAdhan };
}

/** The widget's markup and styles, self-contained (used in a page or a shadow root). */
export function widgetFragment(store, opts, nowMs = Date.now()) {
  const data = publishedTimes(store, nowMs);
  const c = THEMES[opts.theme];
  // Brass on white is too faint for text; deepen the accent on light.
  const accentText = opts.theme === 'light' ? darken(opts.accent, 0.45) : opts.accent;
  const now = zonedParts(nowMs, data.masjid.timezone);
  const nowMin = now.hour * 60 + now.minute;
  const isFriday = new Date(Date.UTC(now.year, now.month - 1, now.day)).getUTCDay() === 5;

  // The next congregation today (Jumu'ah replaces Dhuhr on Fridays).
  const order = ['fajr', isFriday && data.iqamah.jumuah ? 'jumuah' : 'dhuhr', 'asr', 'maghrib', 'isha'];
  const next = order.find((k) => {
    const t = data.iqamah[k];
    if (!t) return false;
    const [h, m] = t.split(':').map(Number);
    return h * 60 + m >= nowMin;
  });

  const row = (key, t, names, note) => {
    const { time, ampm } = to12h(t);
    const isNext = key === next;
    return `<li class="row${isNext ? ' next' : ''}">
      <span class="name">${escapeHtml(names[0])}${isNext ? ' <span class="pill">Next</span>' : ''}
        ${note ? `<span class="note">${escapeHtml(note)}</span>` : ''}</span>
      <span class="ar" lang="ar" dir="rtl">${names[1]}</span>
      <span class="time">${time}<small> ${ampm}</small></span>
    </li>`;
  };

  const iqamahRows = Object.keys(NAMES)
    .filter((k) => data.iqamah[k])
    .map((k) => row(k, data.iqamah[k], NAMES[k],
      k === 'maghrib' && data.maghrib.source === 'sunset'
        ? data.maghrib.offset_minutes ? `Sunset + ${data.maghrib.offset_minutes} min` : 'At sunset'
        : null))
    .join('');
  const adhanRows = opts.showAdhan
    ? Object.keys(ADHAN_NAMES).filter((k) => data.adhan[k]).map((k) => row(`adhan-${k}`, data.adhan[k], ADHAN_NAMES[k])).join('')
    : '';

  const date = new Date(Date.UTC(now.year, now.month - 1, now.day))
    .toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' });
  const updated = data.captured_at
    ? new Date(Date.parse(data.captured_at)).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: data.masjid.timezone })
    : null;

  return `<style>
  .ss { --bg:${c.bg}; --surface:${c.surface}; --text:${c.text}; --muted:${c.muted}; --line:${c.line}; --accent:${opts.accent}; --accent-text:${accentText};
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background: var(--bg); color: var(--text);
    border-radius: 20px; padding: 20px; max-width: 420px; box-sizing: border-box; line-height: 1.3; }
  .ss * { box-sizing: border-box; }
  .ss header { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 4px; }
  .ss h2 { margin: 0; font-size: 18px; font-weight: 800; }
  .ss .title-ar { color: var(--accent-text); font-size: 20px; font-weight: 700; }
  .ss .date { color: var(--muted); font-size: 14px; margin-bottom: 14px; }
  .ss h3 { margin: 16px 0 8px; font-size: 12px; letter-spacing: 1.4px; text-transform: uppercase; color: var(--accent-text); }
  .ss ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
  .ss .row { display: grid; grid-template-columns: 1fr auto auto; align-items: center; gap: 12px;
    background: var(--surface); border-radius: 14px; padding: 12px 14px; border: 1px solid transparent; }
  .ss .row.next { border-color: var(--accent); }
  .ss .name { font-weight: 600; font-size: 16px; display: flex; flex-direction: column; align-items: flex-start; gap: 2px; }
  .ss .note { font-size: 12px; font-weight: 500; color: var(--muted); }
  .ss .pill { display: inline-block; font-size: 11px; font-weight: 800; color: var(--bg); background: var(--accent);
    border-radius: 8px; padding: 2px 6px; vertical-align: middle; }
  .ss .ar { color: var(--accent-text); font-size: 17px; }
  .ss .time { font-size: 22px; font-weight: 800; font-variant-numeric: tabular-nums; min-width: 92px; text-align: right; }
  .ss .time small { font-size: 12px; font-weight: 700; }
  .ss footer { margin-top: 14px; font-size: 12px; color: var(--muted); }
  .ss .empty { color: var(--muted); font-size: 15px; padding: 12px 0; }
</style>
<section class="ss" aria-label="Prayer times at ${escapeHtml(data.masjid.name)}">
  <header><h2>${escapeHtml(data.masjid.name)}</h2><span class="title-ar" lang="ar" dir="rtl">أوقات الصلاة</span></header>
  <div class="date">${escapeHtml(date)}</div>
  <h3>Iqamah</h3>
  ${iqamahRows ? `<ul>${iqamahRows}</ul>` : '<div class="empty">Times will appear here once they’re updated from the masjid board.</div>'}
  ${adhanRows ? `<h3>Adhan</h3><ul>${adhanRows}</ul>` : ''}
  ${updated ? `<footer>Updated from the masjid board · ${escapeHtml(updated)}</footer>` : ''}
</section>`;
}

const WIDGET_JS = `// Snap Salat prayer-times widget.
// <script src="https://YOUR-SERVER/widget.js" data-theme="dark" async></script>
// Optional: data-target="#element" to render inside an existing element,
// data-theme="dark|light", data-accent="#D4AF5F", data-adhan="1".
(function () {
  var script = document.currentScript;
  if (!script) return;
  var host = document.createElement('div');
  var target = script.dataset.target && document.querySelector(script.dataset.target);
  if (target) target.appendChild(host); else script.parentNode.insertBefore(host, script);
  var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
  var params = new URLSearchParams();
  ['theme', 'accent', 'adhan'].forEach(function (k) { if (script.dataset[k]) params.set(k, script.dataset[k]); });
  var url = new URL('widget/fragment?' + params, script.src);
  function load() {
    fetch(url).then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
      .then(function (html) { root.innerHTML = html; })
      .catch(function () {});
  }
  load();
  setInterval(load, 10 * 60 * 1000);
})();
`;

export function publicRoutes({ store }) {
  return {
    'GET /prayer-times.json': (req, res) => {
      sendJson(res, 200, publishedTimes(store), { 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=60' });
    },
    'GET /widget/fragment': (req, res, url) => {
      sendHtml(res, 200, widgetFragment(store, widgetOptions(url, store.settings())), {
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'public, max-age=60',
      });
    },
    'GET /widget': (req, res, url) => {
      const opts = widgetOptions(url, store.settings());
      sendHtml(res, 200, `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Prayer times</title>
<style>body{margin:0;background:transparent}</style></head><body>${widgetFragment(store, opts)}</body></html>`, {
        'Cache-Control': 'public, max-age=60',
      });
    },
    'GET /widget.js': (req, res) => {
      res.writeHead(200, {
        'Content-Type': 'text/javascript; charset=utf-8',
        'Cache-Control': 'public, max-age=3600',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(WIDGET_JS);
    },
  };
}
