---
title: API for masjid websites
permalink: /api.html
---

# Snap Salat API, version 1

This page is for whoever runs a masjid's website or app. If your site
implements these few endpoints, volunteers can update its prayer times by
photographing the masjid's display with the Snap Salat app.

The app does the hard part: it reads the photo on the phone and lets a person
check every time before sending. Your server receives plain, validated JSON.

- A complete implementation with no dependencies, which you can deploy as
  is, is in [`server/`](https://github.com/meelash/snap-salat/tree/main/server).
  It also has an admin page and a website widget. Read it alongside this
  page, or run it to try the app.
- A machine-readable description is in [`openapi.yaml`](openapi.yaml).

## Overview

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/info` | none | Identify the server and its sign-in methods. **Required.** |
| `POST` | `/auth/register` | none | A volunteer asks for an account. It starts *pending*. **Required.** |
| `POST` | `/auth/login` | none | Exchange a username and password for a token. **Required.** |
| `GET` | `/auth/check` | Bearer | Is the token valid, and is this volunteer **approved** yet? **Required.** |
| `POST` | `/prayer-times` | Bearer | Receive new times from a photo. Approved volunteers only. **Required.** |
| `GET` | `/prayer-times` | none | Return the times you have now. Optional. |

Paths are relative to a **base URL** of your choice, for example
`https://yourmasjid.org/snap-salat`. Users type that base URL into the app,
or pick your masjid from the [directory](adding-a-masjid.html).

General rules:

- **HTTPS only.** The app refuses plain `http://` in release builds because
  it sends credentials.
- Request and response bodies are JSON (`Content-Type: application/json`).
- Errors use an HTTP status code and a body like
  `{"error": "machine_code", "message": "Text we can show the user."}`.
  The app shows `message` to the user as is, so write it for a volunteer, not
  a developer.

## `GET /info`

Lets the app check that the address really is a Snap Salat endpoint, show
the masjid's name, and pick a sign-in form.

```json
{
  "api": "snap-salat",
  "version": 1,
  "masjid": {
    "name": "Masjid Al-Noor",
    "timezone": "America/New_York"
  },
  "auth": { "methods": ["password"], "register": true },
  "accepts": {
    "prayers": ["fajr", "dhuhr", "asr", "maghrib", "isha", "jumuah"],
    "adhan": true,
    "image": false
  },
  "max_age_minutes": 1440
}
```

| Field | Required | Meaning |
|---|---|---|
| `api` | yes | Always `"snap-salat"`. |
| `version` | yes | `1` for this document. |
| `masjid.name` | yes | Shown to the user. |
| `masjid.timezone` | no | IANA zone name. Recommended. |
| `auth.methods` | yes | Must include `"password"`. May also include `"token"` (see below). |
| `auth.register` | no | `false` if you're not taking new sign-ups right now. The app then hides its *Register* form. Default `true`. |
| `accepts.prayers` | no | Which prayers you store. Defaults to all. |
| `accepts.adhan` | no | Whether you want adhan (start) times as well as iqamah. Default `true`. |
| `accepts.image` | no | Set `true` if you want the photo itself uploaded. Default `false`. |
| `max_age_minutes` | no | Tell users how old a photo you accept. |

## Volunteers: register, get approved, update

Anyone can install the app, so **an account alone must not allow updates.**
A volunteer registers in the app, and the account starts as `pending`.
Someone at the masjid approves it, for example on your admin page. Only
then may it send times.

```
register ──▶ pending ──(masjid approves)──▶ approved ──(masjid revokes)──▶ revoked
```

The volunteer can sign in while pending. The app shows "waiting for the
masjid to approve you" and checks again with `GET /auth/check`.

### `POST /auth/register`

```json
{
  "username": "yusuf",
  "password": "…",
  "name": "Yusuf Ahmed",
  "contact": "555-0134",
  "note": "I help with the Friday setup"
}
```

| Field | Required | Meaning |
|---|---|---|
| `username` | yes | What they'll sign in with. |
| `password` | yes | At least 8 characters is recommended. |
| `name` | yes | Shown to whoever approves them. |
| `contact` | no | Phone or email, so the masjid can recognise or reach them. |
| `note` | no | Anything they want the approver to know. |

| Status | When | Body |
|---|---|---|
| `201` | Registered, awaiting approval | `{"status": "pending", "message": "Thank you! The masjid will review your request."}` |
| `409` | Username taken | `{"error": "username_taken", "message": "…"}` |
| `422` | Invalid fields | `{"error": "invalid", "message": "…", "fields": {"password": "at least 8 characters"}}` |
| `403` | Not taking sign-ups | `{"error": "registration_closed", "message": "…"}` |
| `429` | Too many sign-ups from one address | `{"error": "rate_limited", "message": "…"}` |

Store only a slow hash of the password (scrypt, bcrypt or argon2). Rate-limit
this endpoint.

### `POST /auth/login`

```json
{ "username": "yusuf", "password": "…" }
```

Success, `200`. This works for pending volunteers too, so they can check
their status:

```json
{
  "access_token": "4f9c…",
  "token_type": "Bearer",
  "expires_in": 2592000,
  "user": { "name": "Yusuf Ahmed", "status": "pending" }
}
```

Wrong credentials, `401`:

```json
{ "error": "invalid_credentials", "message": "Wrong username or password." }
```

- `expires_in` is in seconds and optional. When it runs out, or whenever you
  answer `401`, the app asks the user to sign in again.
- Rate-limit this endpoint. The example server allows 10 attempts per minute
  per IP address.
- The app stores the token in the phone's secure keystore. It never stores
  the password.

### `GET /auth/check`: the verification check

Header: `Authorization: Bearer <token>`. Answer `200` with the volunteer's
current status:

```json
{ "user": { "name": "Yusuf Ahmed", "username": "yusuf", "status": "approved" } }
```

| `status` | Meaning |
|---|---|
| `pending` | Registered; nobody at the masjid has approved them yet. |
| `approved` | May send prayer times. |
| `revoked` | Was approved, or was declined; may not send times. |

Answer `401` if the token is missing, wrong or expired. You may also end a
revoked volunteer's tokens, so they get `401`.

### `token` (optional)

As well as `password`, you can offer `token`: you give a trusted volunteer a
long random token, for example from your website's admin area, and they
paste it into the app. Such tokens are approved by definition, and
`GET /auth/check` should report `"status": "approved"` for them.

## `POST /prayer-times`

Header: `Authorization: Bearer <token>`. The app sends this after the user
has reviewed and confirmed the times.

```json
{
  "captured_at": "2026-10-09T16:53:38-04:00",
  "captured_at_source": "exif",
  "submitted_at": "2026-10-09T16:55:02-04:00",
  "date": "2026-10-09",
  "iqamah": {
    "fajr": "06:15",
    "dhuhr": "13:30",
    "asr": "17:00",
    "maghrib": "18:33",
    "isha": "20:15",
    "jumuah": "13:45"
  },
  "adhan": {
    "fajr": "05:41",
    "sunrise": "07:02"
  },
  "display_clock": "16:53",
  "recognition": {
    "reader": "analog-clocks",
    "confidence": 0.75,
    "edited": ["maghrib"],
    "warnings": []
  },
  "client": { "app": "snap-salat", "version": "1.0.0", "platform": "android" },
  "location": { "lat": 41.34291, "lng": -72.92657, "source": "exif" },
  "image": { "sha256": "9b1c…" }
}
```

| Field | Always sent | Meaning |
|---|---|---|
| `captured_at` | yes | When the photo was taken: ISO 8601 with UTC offset. **Use this to decide whether the times are up to date.** |
| `captured_at_source` | yes | How the app knows: `exif` (from the photo's camera metadata), `camera` (photo taken in the app just now) or `file` (the file's date, because the photo had no camera metadata; least reliable). Users can't edit this time in the app. |
| `submitted_at` | yes | When the phone sent the request. |
| `date` | yes | Local date of the photo, `YYYY-MM-DD`. The times apply from this date. |
| `iqamah` | yes | Congregation times. Keys: `fajr`, `dhuhr`, `asr`, `maghrib`, `isha`, `jumuah`. May be partial or empty. |
| `adhan` | no | Start times (when each prayer's time begins), sent only when the display itself shows them, e.g. a printed table with "Begins" and "Jamaat" columns. Analog clock boards usually show only iqamah. Keys: `fajr`, `sunrise`, `dhuhr`, `asr`, `maghrib`, `isha`. |
| `display_clock` | no | What the board's own clock showed, if it has one. If it matches `captured_at`, you can be confident the photo is real and recent. |
| `recognition` | no | How the times were read: `reader` is `analog-clocks` or `text`, `confidence` runs 0–1, and `edited` lists times the user changed by hand. Useful for auditing. |
| `client` | no | App name, version and platform. |
| `location` | no | Where the photo was taken, from the photo's own GPS data (`"source": "exif"`), when it has any. Compare it with the masjid's location to flag photos taken somewhere else. It's never edited by the user, and missing whenever the camera didn't record a location. |
| `image.sha256` | no | Hex SHA-256 of the original photo. Lets you spot the same photo being sent twice. |
| `image.jpeg_base64` | no | The photo, shrunk to at most 1600 px, if `accepts.image` is true. |

All times are **24-hour `HH:MM` in the masjid's local time**. At least one
time is always present. A missing key means "not on this display" or "the
user cleared it", not "remove this prayer", so merge partial updates with the
times you already have.

**Maghrib.** Many masajid pray Maghrib at sunset, which changes every day, so
the Maghrib clock on their board is often left unset or ignored. The app
sends whatever the board shows. If your masjid prays at sunset, or at a fixed
number of minutes after it, **ignore the submitted `maghrib`** and compute it
yourself from sunset for the masjid's location. Deciding this is the
server's job, not the app's.

**Photo time.** `captured_at` can't be edited in the app. A photo taken in
the app (`camera`) is the most trustworthy. `exif` comes from the photo file,
which a determined person could alter before choosing it. If that matters to
you, accept only `camera`, or compare `display_clock` with `captured_at`.

### Responses

| Status | When | Body |
|---|---|---|
| `200` or `201` | Accepted | `{"status": "accepted", "message": "Optional text shown to the user"}` |
| `401` | Token missing, wrong or expired | `{"error": "unauthorized", "message": "…"}`. The app asks the user to sign in again, then retries once. |
| `403` | The volunteer isn't approved (pending or revoked) | `{"error": "not_approved", "message": "Your account is waiting for the masjid to approve it."}` |
| `409` | You already have times from a newer photo | `{"error": "stale", "message": "…"}` |
| `422` | Something failed validation | `{"error": "invalid", "message": "…", "fields": {"iqamah.fajr": "must be HH:MM"}}` |

### What a server should check

The example server does all of these:

1. The bearer token is valid **and the volunteer is approved**.
2. `captured_at` parses, isn't in the future (allow a few minutes of clock
   skew), and isn't older than your `max_age_minutes`.
3. It's newer than the photo behind the times you already have. If not,
   answer `409 stale`. This stops an old photo from overwriting a new one.
4. Every time matches `^([01]\d|2[0-3]):[0-5]\d$` and every key is known.
5. There is at least one time.

Optionally, flag updates for a person to review. The example server flags:

- a `location` farther than a set distance from the masjid;
- a `display_clock` that disagrees with `captured_at`, which means the board's
  clock is wrong or the photo isn't what it claims to be;
- `captured_at_source: "file"`.

## `GET /prayer-times` (optional)

No authentication required. It returns what you have now, in the same shape:

```json
{
  "updated_at": "2026-10-09T20:55:03Z",
  "captured_at": "2026-10-09T16:53:38-04:00",
  "date": "2026-10-09",
  "iqamah": { "fajr": "06:15", "dhuhr": "13:30", "asr": "17:00", "maghrib": "18:33", "isha": "20:15", "jumuah": "13:45" },
  "adhan": {}
}
```

Answer `404` if you don't offer it.

## Trying it locally

```sh
cd server
INSECURE_COOKIES=1 node server.mjs create-admin admin
INSECURE_COOKIES=1 npm start
```

Sign in at <http://localhost:8080/admin>. Then, in a debug build of the
app, choose **Enter address**: `http://10.0.2.2:8080/snap-salat` from the
Android emulator, or `http://<your computer's LAN IP>:8080/snap-salat` from a
phone. Register in the app, approve yourself on the admin page, and send a
photo. Release builds only accept `https://`. To deploy it for real, see
[`server/README.md`](https://github.com/meelash/snap-salat/blob/main/server/README.md).

Run the server's tests with `cd server && npm test`.

## Versioning

Additive changes, such as new optional fields, keep `version: 1`. Servers
must ignore fields they don't know. Breaking changes will bump `version`, and
the app will keep supporting version 1.
