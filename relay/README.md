# Snap Salat notification relay

Push notifications for the Snap Salat app go through Firebase Cloud
Messaging (FCM). Sending them needs the app's Firebase key, which can't be
given to every masjid server, because then any of them could notify every
user of the app. So masjid servers call this relay, and only the relay holds
the key.

```
masjid server ──POST /v1/notify──▶ relay ──FCM HTTP v1──▶ phones
                                     │
                                     └─ times_changed: reads the masjid's own GET /prayer-times
```

| Event | Sent to | Text |
|---|---|---|
| `approval_waiting` | the admins' devices the server lists | "A volunteer is waiting for your approval." |
| `approved` | the volunteer's devices | "You've been approved. You can now send prayer times from the app." |
| `times_changed` | everyone following the masjid (an FCM topic) | "Isha 8:00 PM (was 8:15 PM)" |

**Nobody can make up a notification's text.** It's fixed for the first two
events. For `times_changed`, the relay reads the times from the masjid's own
public `GET /prayer-times` and sends only when an iqamah time differs from
what it saw last time, so asking it again does nothing. Device tokens are
known only to the masjid server the app registered them with.

FCM costs nothing, and at this scale the relay fits easily in Cloudflare's
free Workers plan. It has no dependencies and runs on
[Cloudflare Workers](#deploy-on-cloudflare-workers) or
[Node](#or-run-it-with-node).

## One-time setup

### 1. Firebase project

1. Create a project at <https://console.firebase.google.com> (Analytics not
   needed).
2. **Add an Android app** with package name `org.snapsalat.snap_salat`.
   You don't need `google-services.json`; the app takes its settings from
   build flags (step 4).
3. **Add an iOS app** with bundle ID `org.snapsalat.snapSalat`.
4. **Project settings → Service accounts → Generate new private key.** This
   JSON file is the relay's key. Keep it secret: anyone holding it can send
   notifications to every user of the app. Never commit it (`.gitignore`
   already ignores `relay/service-account*.json`).

### 2. Apple Push Notifications (iOS only)

Push on iOS needs the Apple Developer Program, which you need anyway to
publish on the App Store.

1. In the Apple Developer site, go to **Certificates, IDs & Profiles → Keys**
   and create a key with **Apple Push Notifications service (APNs)**.
   Download the `.p8` file.
2. In Firebase, go to **Project settings → Cloud Messaging → Apple app
   configuration** and upload it with its Key ID and your Team ID.
3. In Xcode (`app/ios/Runner.xcworkspace`), open **Runner → Signing &
   Capabilities → + Capability → Push Notifications**.

### 3. Deploy the relay

#### Deploy on Cloudflare Workers

```sh
cd relay
npx wrangler login
npx wrangler kv namespace create TIMES        # paste the id into wrangler.toml
npx wrangler secret put FCM_SERVICE_ACCOUNT < service-account.json
npx wrangler deploy
```

It prints the relay's address, e.g.
`https://snap-salat-relay.<you>.workers.dev`. Check that it answers at `/`
with `{"service": "snap-salat-relay", "version": 1}`.

To limit abuse, add a **rate-limiting rule** (Security → WAF; one rule is
free) for `/v1/notify`, e.g. 30 requests per minute per IP address. Real
masjid servers send a handful of requests a day.

#### Or run it with Node

```sh
FCM_SERVICE_ACCOUNT=/etc/snap-salat/service-account.json DATA_FILE=/var/lib/snap-salat-relay/data.json \
  node relay/node.mjs
```

It listens on `127.0.0.1:8090`; put Caddy or nginx in front of it for
HTTPS, as with the example server. `ALLOW_HTTP=1` accepts plain-http masjid
addresses, for local testing only.

### 4. Build the app with push

Copy `app/push.example.json` to `app/push.json` and fill it in:

- the relay's address;
- the project ID and sender ID (**Project settings → General** and **Cloud
  Messaging**);
- the app IDs and API keys of the Android and iOS apps (**Project settings →
  General → Your apps**).

None of these values is secret. Then build with them:

```sh
cd app
flutter run --dart-define-from-file=push.json
flutter build appbundle --dart-define-from-file=push.json
```

Without the file the app builds and works as before. It just never offers
notifications.

### 5. Turn it on in each masjid's server

In the example server's admin page, go to **Settings → Notifications**,
tick **Send push notifications**, and enter the relay's address. You can
also start the server with `PUSH_RELAY_URL=…` so that address is filled in
already. **This server's address in the app** must be the API address
exactly as the app knows it, from the masjid directory or as volunteers type
it, because that's what the app follows.

Other servers: see [Push notifications](../docs/api.md#push-notifications-optional)
in the API.

## The API

```http
POST /v1/notify
Content-Type: application/json

{"event": "times_changed", "api": "https://yourmasjid.org/snap-salat"}
{"event": "approval_waiting", "api": "…", "masjid": "Masjid Al-Noor", "tokens": ["…"], "count": 2}
{"event": "approved", "api": "…", "masjid": "…", "tokens": ["…"]}
```

It answers `200 {"sent": 1, "invalid_tokens": [...]}`. Forget the invalid
tokens, because those apps were uninstalled. `times_changed` can also answer
`{"sent": 0, "reason": "unchanged"}`. Errors: `422` for a bad request (at
most 40 tokens, `api` must be `https://`), `502` if Firebase failed.

**Topics.** Followers of a masjid are subscribed to
`times_` + the first 40 hex digits of SHA-256 of its canonical API address
(lower-case scheme and host, no default port or trailing slash). The app
computes the same name in `app/lib/services/push_service.dart`. Both test
suites share a test vector, so the two can't drift apart.

## Tests

```sh
cd relay && npm test
```
