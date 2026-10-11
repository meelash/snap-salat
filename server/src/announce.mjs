// Drafts an announcement in the masjid's announcement list (the
// bulletin-board app's /api/v1) when the prayer times change, e.g.
//
//   POST {announce_url}/api/v1/posts
//   Authorization: Bearer …   Idempotency-Key: prayer-times-2026-11-02-…
//   {"template": "prayer_times", "templateData": {...}, "bodyText": "...", "submit": true}
//
// Only when (1) at least one iqamah time really differs from what was
// published before, and (2) the photo is later than the one behind the last
// announcement. Never blocks or fails the volunteer's submission.

import { createHash } from 'node:crypto';

const TEMPLATE = 'prayer_times';
const NAMES = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha', jumuah: "Jumu'ah" };
const KEYS = Object.keys(NAMES);

export const to12h = (t) => {
  const [h, m] = t.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};

/**
 * Times that differ between the published times and an incoming
 * submission. A prayer with no earlier value is not a change (that's the
 * first time it's set), and Maghrib doesn't count while it's calculated
 * from sunset, since the board's Maghrib is ignored then.
 */
export function detectChanges(previous, incoming, settings) {
  const changes = [];
  for (const key of KEYS) {
    if (key === 'maghrib' && settings.maghrib_mode === 'sunset') continue;
    const from = previous?.[key], to = incoming?.[key];
    if (from && to && from !== to) changes.push({ key, from, to });
  }
  return changes;
}

/** How Maghrib reads in the announcement. */
function maghribText(settings, iqamah) {
  if (settings.maghrib_mode === 'sunset') {
    const offset = parseInt(settings.maghrib_offset, 10) || 0;
    return offset ? `Sunset + ${offset} min` : 'Sunset';
  }
  return iqamah.maghrib ? to12h(iqamah.maghrib) : undefined;
}

/** The request body for the announcement list's posts API. */
export function buildPost({ settings, iqamah, changes, effectiveDate }) {
  const templateData = { effectiveDate };
  for (const key of KEYS) {
    const value = key === 'maghrib' ? maghribText(settings, iqamah) : iqamah[key] && to12h(iqamah[key]);
    if (value) templateData[key] = value;
  }
  const list = changes.map((c) => `${NAMES[c.key]} ${to12h(c.to)} (was ${to12h(c.from)})`);
  const date = new Date(`${effectiveDate}T12:00:00Z`)
    .toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' });
  return {
    template: TEMPLATE,
    templateData,
    bodyText: `Iqamah times change from ${date}: ${list.join(', ')}.`,
    submit: settings.announce_submit === '1',
  };
}

/** Same change on the same day → same key, so retries never duplicate a post. */
export function idempotencyKey(effectiveDate, iqamah) {
  const hash = createHash('sha256').update(JSON.stringify(KEYS.map((k) => iqamah[k] ?? ''))).digest('hex').slice(0, 10);
  return `prayer-times-${effectiveDate}-${hash}`;
}

const base = (settings) => settings.announce_url.replace(/\/+$/, '');

export function announcer({ store, log = () => {}, fetchImpl = fetch }) {
  async function send(id) {
    const a = store.announcement(id);
    const settings = store.settings();
    try {
      const res = await fetchImpl(`${base(settings)}/api/v1/posts`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${settings.announce_token}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': a.idempotency_key,
        },
        body: JSON.stringify(a.request),
        signal: AbortSignal.timeout(15_000),
      });
      const text = await res.text();
      let body = {};
      try {
        body = JSON.parse(text);
      } catch {
        // Not JSON; the status code tells us enough.
      }
      // Errors are {"error": "Missing template fields: Effective date"}.
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${body.error ?? text.slice(0, 300)}`);
      // 201 for a new post, 200 when the idempotency key replays one.
      const remoteId = body.id ?? null;
      store.finishAnnouncement(id, { status: 'sent', remoteId: remoteId == null ? null : String(remoteId) });
      log(`announcement drafted for ${a.effective_date}${remoteId != null ? ` (post ${remoteId})` : ''}`);
    } catch (err) {
      store.finishAnnouncement(id, { status: 'failed', error: String(err.message ?? err).slice(0, 500) });
      log(`announcement for ${a.effective_date} failed: ${err.message ?? err}`);
    }
    return store.announcement(id);
  }

  return {
    /**
     * Called after a submission is stored. `previous` is the published
     * iqamah before it, `merged` the iqamah after merging it in.
     * Resolves to the announcement record, or null when none was needed.
     */
    async afterSubmission({ submissionId, capturedAtMs, effectiveDate, previous, incoming, merged }) {
      const settings = store.settings();
      if (settings.announce_enabled !== '1' || !settings.announce_url || !settings.announce_token) return null;
      const changes = detectChanges(previous, incoming, settings);
      if (!changes.length) return null;
      const last = store.lastAnnouncement();
      if (last && last.captured_at_ms >= capturedAtMs) {
        log(`not announcing: photo is not later than the last announcement's`);
        return null;
      }
      const request = buildPost({ settings, iqamah: merged, changes, effectiveDate });
      const id = store.addAnnouncement({
        submissionId,
        capturedAtMs,
        effectiveDate,
        changes,
        request,
        idempotencyKey: idempotencyKey(effectiveDate, merged),
      });
      return send(id);
    },

    retry: (id) => send(id),

    /** The post's status in the announcement list (draft → … → sent). */
    async remoteStatus(remoteId) {
      const settings = store.settings();
      try {
        const res = await fetchImpl(`${base(settings)}/api/v1/posts/${encodeURIComponent(remoteId)}`, {
          headers: { Authorization: `Bearer ${settings.announce_token}` },
          signal: AbortSignal.timeout(3000),
        });
        if (!res.ok) return null;
        // draft | pending_approval | changes_requested | approved | scheduled | sending | sent | archived
        return (await res.json()).status ?? null;
      } catch {
        return null;
      }
    },

    /**
     * Checks the address and key without creating anything: the key works,
     * the prayer_times template and its category exist, and the key can
     * read posts (for the status column). Returns {ok, message, fields}.
     */
    async test() {
      const settings = store.settings();
      if (!settings.announce_url || !settings.announce_token) {
        return { ok: false, message: 'Enter the address and API key first.' };
      }
      const get = (path) => fetchImpl(`${base(settings)}/api/v1${path}`, {
        headers: { Authorization: `Bearer ${settings.announce_token}` },
        signal: AbortSignal.timeout(8000),
      });
      try {
        // {categories: [{slug, name}], templates: [{key, label, defaultCategory, fields: [{name, required}]}]}
        const res = await get('/categories');
        if (res.status === 401) return { ok: false, message: 'The API key was not accepted (or has been revoked).' };
        if (!res.ok) return { ok: false, message: `The announcement list answered HTTP ${res.status}.` };
        const { categories = [], templates = [] } = await res.json();
        const template = templates.find((t) => t.key === TEMPLATE);
        if (!template) return { ok: false, message: `Connected, but there is no "${TEMPLATE}" template.` };
        if (template.defaultCategory && !categories.some((c) => c.slug === template.defaultCategory)) {
          return {
            ok: false,
            message: `Connected, but the "${template.defaultCategory}" category is missing or turned off, `
              + 'so posts would be refused. Add or turn it on in the announcement list.',
          };
        }
        const fields = (template.fields ?? []).map((f) => f.name);
        const missing = KEYS.filter((k) => !fields.includes(k));
        const canRead = (await get('/posts')).ok;
        return {
          ok: true,
          message: `Connected. The "${template.label ?? TEMPLATE}" template is ready.`
            + (missing.length ? ` It has no field for ${missing.join(', ')}; those won't be included.` : '')
            + (canRead ? '' : ' This key can’t read posts (posts:read), so post status won’t show here.')
            + ' The key also needs posts:create, and posts:submit if drafts are submitted for approval.',
          fields,
        };
      } catch (err) {
        return { ok: false, message: `Couldn't reach it: ${err.message ?? err}` };
      }
    },
  };
}
