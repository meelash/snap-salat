---
title: Example server
description: A complete, small server for one masjid. It implements the Snap Salat API and adds an admin page, a website widget and announcements.
---

# The example server

A complete, small server for one masjid. It's the reference implementation of
the [Snap Salat API](api.html), and it's built to be **deployed as is**:

- **No dependencies.** It needs Node.js 22.13 or later, and nothing else.
- **One SQLite file**, plus a folder of photos.
- It runs on the smallest VPS, either in Docker behind Caddy or with systemd.

It's what the Islamic Center of Hamden runs. Source:
[`server/`](https://github.com/meelash/snap-salat/tree/main/server).

## What it does

### Approves volunteers

Anyone can install the app and register, but **only volunteers you approve can
update the times**. The admin page lists new sign-ups with their name, contact
and note. Approve or decline each one, and revoke anyone later; revoking signs
them out immediately. You can also close sign-ups altogether.

<figure>
  <img src="{{ '/assets/img/admin-overview.png' | relative_url }}" alt="Admin overview: today's published times, volunteers waiting for approval and approved, recent announcements" width="1100" height="1075">
  <figcaption>The admin overview: what's published today, who last updated it (from which photo, and what the board's clock showed), volunteers, and announcements.</figcaption>
</figure>

### Checks every update

Every update is kept with:

- who sent it;
- when the photo was taken, and how the app knows (camera, the photo's own data, or the file date);
- what the board's own clock showed;
- which times the volunteer corrected by hand;
- the photo itself, if you choose to receive photos.

Older photos can never overwrite newer times, and photos older than a limit
you set are refused.

Updates that deserve a second look are **flagged** on the admin page:

- the photo was taken farther than a set distance from the masjid (500 m by
  default), using the photo's own GPS data;
- the board's own clock disagrees with the photo's time;
- the photo's time came only from the file date.

Nothing is rejected for these. They tell you which photos to open.

### Maghrib from sunset

Many masajid pray Maghrib at sunset, so the Maghrib clock on the board isn't
kept up to date. Choose **calculate from today's sunset**, at sunset or 3 to
20 minutes after, optionally rounded up to 5 minutes. The server works out
sunset for your masjid's location every day, and ignores the board's Maghrib
clock.

<figure>
  <img src="{{ '/assets/img/admin-maghrib.png' | relative_url }}" alt="Maghrib settings: use the board, or calculate from sunset plus an offset" width="1100" height="330">
</figure>

### A widget for your website

One line of HTML shows the current iqamah times on any page. It has dark
and light themes and a custom accent colour, highlights the next prayer, and
refreshes itself. Its styles are isolated, so they can't clash with your
site.

```html
<script src="https://your-server/widget.js" async></script>
```

Options:

- `data-theme="light"`;
- `data-accent="#1E3A8A"`;
- `data-adhan="1"` to also show adhan times;
- `data-target="#prayer-times"` to render inside an element already on your
  page.

If your site doesn't allow scripts, use an iframe:

```html
<iframe src="https://your-server/widget" title="Prayer times"
        style="border:0;width:100%;max-width:420px;height:560px"></iframe>
```

Or build your own design from `https://your-server/prayer-times.json`, which
is open to any website:

```json
{
  "masjid": { "name": "Islamic Center of Hamden", "timezone": "America/New_York" },
  "date": "2026-10-11",
  "iqamah": { "fajr": "06:00", "dhuhr": "13:30", "asr": "16:45", "maghrib": "18:24", "isha": "20:00", "jumuah": "13:45" },
  "adhan": {},
  "maghrib": { "source": "sunset", "sunset": "18:19", "offset_minutes": 5 },
  "captured_at": "2026-10-11T13:52:10-04:00",
  "updated_at": "2026-10-11T17:52:41.000Z"
}
```

<div class="widgets">
  <img src="{{ '/assets/img/widget-dark.png' | relative_url }}" alt="Widget, dark theme" width="600" height="779">
  <img src="{{ '/assets/img/widget-light.png' | relative_url }}" alt="Widget, light theme" width="600" height="779">
</div>

### Announces changes

If your masjid uses an announcement list (the bulletin-board app's
`/api/v1`), the server can draft a "prayer times" post whenever a photo
**really changes** an iqamah time. It doesn't post when:

- a prayer is being set for the very first time;
- only Maghrib changed while Maghrib follows sunset;
- the photo is older than the one behind the last announcement.

The post carries all the current times and a summary such as "Fajr 6:00 AM
(was 6:15 AM)". It goes into your list's approval queue, or stays a draft;
you choose which.

<figure>
  <img src="{{ '/assets/img/admin-announcements.png' | relative_url }}" alt="Announcement settings: address, API key, submit for approval, and a connection test" width="1100" height="440">
</figure>

Sending happens in the background, so it never delays a volunteer. **Save and
test connection** checks your API key, the `prayer_times` template and its
category without creating anything. The overview shows each post's live
status, with a **Retry** button for any that failed.

## Deploying it

You need a small VPS (1 CPU and 1 GB of memory is plenty) and a domain name
pointing at it. The app only talks to HTTPS servers, and Caddy gets the
certificate for you.

### With Docker

```sh
# on the server, once
apt-get install -y docker.io docker-compose-v2
mkdir -p /opt/snap-salat && cd /opt/snap-salat
printf "COMPOSE_PROFILES=standalone\nSNAP_DOMAIN=prayer.yourmasjid.org\n" > .env

# from your computer, each time you deploy
server/deploy/deploy.sh root@your-server

# create your admin account
ssh root@your-server docker exec -it snap-salat \
  node --disable-warning=ExperimentalWarning server.mjs create-admin admin
```

Then open `https://prayer.yourmasjid.org/admin`, sign in, and fill in
**Settings**: the masjid's name, time zone, location (for sunset) and Maghrib
rule.

If another Docker stack on the same machine already serves HTTPS, Snap Salat
can share its Caddy instead. The
[server README](https://github.com/meelash/snap-salat/blob/main/server/README.md)
explains how, and also covers installing without Docker (systemd and Caddy),
backups, updates and logs.

### Then

- Volunteers enter `https://prayer.yourmasjid.org/snap-salat` in the app, or
  pick your masjid once it's [in the directory](adding-a-masjid.html).
- Add the widget to your website from the admin page's **Website widget**
  tab, which gives you the exact snippet and a live preview.

## Security

- Passwords are stored as scrypt hashes, and sign-in tokens are stored hashed.
- The admin page uses an HttpOnly, SameSite=Strict cookie and a CSRF token on
  every form.
- Sign-in and registration are rate-limited.
- The service listens only on the internal network; Caddy is the only way in.
- The systemd unit can only write its own data folder.

## Running it locally

```sh
cd server
INSECURE_COOKIES=1 node server.mjs create-admin admin
INSECURE_COOKIES=1 npm start          # http://localhost:8080/admin
npm test
```

A debug build of the app can then use `http://10.0.2.2:8080/snap-salat` from
the Android emulator, or `http://localhost:8080/snap-salat` from a phone
connected over USB after running `adb reverse tcp:8080 tcp:8080`.
