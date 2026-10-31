// Firebase Cloud Messaging, HTTP v1 API, with a service account key.
// Uses only fetch and WebCrypto, so it runs on Cloudflare Workers and Node.

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

const b64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlJson = (obj) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

async function importKey(pem) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, '')), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

/**
 * Sends messages for one Firebase project. `serviceAccount` is the JSON key
 * file from the Firebase console (Project settings → Service accounts).
 */
export function fcmClient(serviceAccount, { fetchImpl = fetch, now = () => Date.now() } = {}) {
  const tokenUri = serviceAccount.token_uri ?? 'https://oauth2.googleapis.com/token';
  let key = null;
  let access = null; // { token, expiresAt }

  async function accessToken() {
    if (access && access.expiresAt > now() + 60_000) return access.token;
    key ??= await importKey(serviceAccount.private_key);
    const iat = Math.floor(now() / 1000);
    const unsigned = `${b64urlJson({ alg: 'RS256', typ: 'JWT' })}.${b64urlJson({
      iss: serviceAccount.client_email, scope: SCOPE, aud: tokenUri, iat, exp: iat + 3600,
    })}`;
    const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
    const res = await fetchImpl(tokenUri, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${unsigned}.${b64url(signature)}`,
      }),
    });
    if (!res.ok) throw new Error(`Google sign-in failed: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
    const json = await res.json();
    access = { token: json.access_token, expiresAt: now() + (json.expires_in ?? 3600) * 1000 };
    return access.token;
  }

  /**
   * Sends one message (`{token}` or `{topic}`, plus notification/data).
   * Resolves to "sent", "invalid_token" (uninstalled app, expired token),
   * or throws for anything else.
   */
  async function send(message) {
    const res = await fetchImpl(`https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ message }),
    });
    if (res.ok) return 'sent';
    const text = await res.text();
    let error = {};
    try {
      error = JSON.parse(text).error ?? {};
    } catch {
      // Not JSON.
    }
    const code = (error.details ?? []).map((d) => d.errorCode).find(Boolean);
    if (message.token && (res.status === 404 || code === 'UNREGISTERED' || code === 'INVALID_ARGUMENT')) {
      return 'invalid_token';
    }
    throw new Error(`FCM HTTP ${res.status}: ${error.message ?? text.slice(0, 200)}`);
  }

  return { send };
}
