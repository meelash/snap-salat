// The FCM topic for a masjid's "times changed" notifications, derived from
// its API base URL. The app computes the same name (app/lib/services/push.dart)
// and subscribes to it; keep the two in step.

/**
 * A masjid API address in one canonical spelling: lower-case scheme and
 * host, no default port, no trailing slash, query or fragment.
 * Null if it isn't an http(s) URL.
 */
export function canonicalApi(input) {
  let url;
  try {
    url = new URL(String(input));
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  // URL lower-cases the scheme and host and drops default ports already.
  const path = url.pathname.replace(/\/+$/, '');
  return `${url.protocol}//${url.host}${path}`;
}

/** `times_` + the first 40 hex digits of SHA-256 of the canonical address. */
export async function timesTopic(api) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonicalApi(api)));
  const hex = [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `times_${hex.slice(0, 40)}`;
}
