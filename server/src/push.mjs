// Push notifications, sent through a relay (relay/ in this repository).
//
// Only the relay holds the app's Firebase key, so this server never talks
// to Firebase itself; it tells the relay what happened:
//
//   POST {push_relay_url}/v1/notify
//   {"event": "approval_waiting", "api": "https://…/snap-salat", "masjid": "…", "tokens": [...], "count": 2}
//   {"event": "approved", "api": …, "masjid": …, "tokens": [...]}
//   {"event": "times_changed", "api": …}
//
// For times_changed the relay reads GET /prayer-times itself and notifies
// everyone following this masjid; the other two go to the device tokens
// the app registered here (POST /push/register). Never blocks or fails
// the request that caused it.

// The relay accepts at most this many tokens per request.
const BATCH = 40;

export const relayBase = (settings) => settings.push_relay_url.replace(/\/+$/, '');

export function pusher({ store, log = () => {}, fetchImpl = fetch }) {
  const enabled = (s) => s.push_enabled === '1' && s.push_relay_url && s.push_api_url;

  async function notify(body) {
    const settings = store.settings();
    if (!enabled(settings)) return null;
    const request = { api: settings.push_api_url, masjid: settings.masjid_name, ...body };
    try {
      const res = await fetchImpl(`${relayBase(settings)}/v1/notify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(request),
        signal: AbortSignal.timeout(15_000),
      });
      const text = await res.text();
      let json = {};
      try {
        json = JSON.parse(text);
      } catch {
        // Not JSON; the status code tells us enough.
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${json.message ?? text.slice(0, 300)}`);
      // Uninstalled apps, expired tokens: stop sending to them.
      if (Array.isArray(json.invalid_tokens) && json.invalid_tokens.length) {
        store.removePushDevices(json.invalid_tokens);
      }
      return json;
    } catch (err) {
      log(`push ${body.event} failed: ${err.message ?? err}`);
      return null;
    }
  }

  async function toTokens(event, tokens, extra = {}) {
    const results = [];
    for (let i = 0; i < tokens.length; i += BATCH) {
      results.push(await notify({ event, tokens: tokens.slice(i, i + BATCH), ...extra }));
    }
    return results;
  }

  return {
    /** A volunteer registered: tell the admins who have the app. */
    approvalWaiting: () => toTokens('approval_waiting', store.adminPushTokens(), { count: store.pendingCount() }),

    /** A volunteer was approved: tell them. */
    approved: (userId) => toTokens('approved', store.userPushTokens(userId)),

    /** The published times changed: the relay tells everyone following. */
    timesChanged: () => notify({ event: 'times_changed' }),

    /** What /info tells the app, so it knows notifications will come. */
    info() {
      const settings = store.settings();
      return enabled(settings) ? { relay: relayBase(settings) } : undefined;
    },
  };
}
