# Snap Salat example server

A complete, small server for one masjid. It has no npm dependencies and needs Node 22.13 or later.

- **The Snap Salat API** ([docs/api.md](../docs/api.md)) at `/snap-salat`. Volunteers enter this address in the app, register, and can send times once you approve them.
- **An admin page** at `/admin`, where you:
  - approve or revoke volunteers;
  - set Maghrib to follow the board, or to be calculated from today's sunset (at sunset or a few minutes after, optionally rounded up to 5 minutes);
  - review each update with its photo;
  - get the code that embeds the widget on your website.
- **Public prayer times:**
  - `/prayer-times.json`, which any website can read;
  - `/widget.js`, a styled widget you add to your site with one line;
  - `/widget`, the same widget as a page you can put in an iframe.

Each update is checked against the masjid's location (from the photo's GPS
data) and the board's own clock, and anything suspicious is flagged on the
admin page for review.

Data lives in one SQLite file (Node's built-in `node:sqlite`) plus a folder of uploaded photos.

## Try it locally

```sh
cd server
INSECURE_COOKIES=1 DATA_DIR=./data node server.mjs create-admin admin
INSECURE_COOKIES=1 DATA_DIR=./data npm start
```

Then:

- Open <http://localhost:8080/admin>, sign in, and fill in **Settings**.
- In a **debug build** of the app, use *Enter address*:
  - from the Android emulator: `http://10.0.2.2:8080/snap-salat`;
  - from a phone on USB: run `adb reverse tcp:8080 tcp:8080`, then use `http://localhost:8080/snap-salat`.
- Register in the app, approve yourself on the admin page, and send a photo.
- See the result at <http://localhost:8080/widget>.

`INSECURE_COOKIES=1` lets the admin cookie work over plain `http://` while you test. Don't use it on the real server.

Run the tests with `npm test`.

## Deploy with Docker (how the Islamic Center of Hamden runs it)

`deploy/deploy.sh` builds the image on your computer, uploads it over SSH,
and starts it with `deploy/docker-compose.yml` in `/opt/snap-salat`.

**Once, on the server:**

```sh
apt-get install -y docker.io docker-compose-v2
mkdir -p /opt/snap-salat && cd /opt/snap-salat
printf "COMPOSE_PROFILES=standalone\nSNAP_DOMAIN=snapsalat.example.org\n" > .env
```

**Each deploy, from your computer:**

```sh
server/deploy/deploy.sh root@your-server
```

**Create the admin account:**

```sh
docker exec -it snap-salat node --disable-warning=ExperimentalWarning server.mjs create-admin admin
```

The `standalone` profile adds a Caddy container that serves `SNAP_DOMAIN`
with automatic HTTPS. Point the domain's DNS `A` record at the server first.

**Sharing a Caddy with another stack** (e.g. the bulletin-board, whose Caddy
also wants ports 80 and 443):

1. Remove `COMPOSE_PROFILES=standalone` from `/opt/snap-salat/.env`, then run
   `docker compose up -d --remove-orphans`. This stops Snap Salat's Caddy.
2. Attach the other stack's `caddy` service to the external `edge` network,
   and its `app` service too if Snap Salat should reach the announcement list
   at `http://app:3000`:

   ```yaml
   networks:
     edge: { external: true }
   ```

3. Add a site block to that Caddyfile:

   ```
   snapsalat.example.org {
       encode zstd gzip
       request_body {
           max_size 20MB
       }
       reverse_proxy snap-salat:8080
   }
   ```

Data lives in the `snap-salat-data` Docker volume. Back it up with:

```sh
docker run --rm -v snap-salat_snap-salat-data:/d -v $PWD:/b alpine tar czf /b/snap-salat-data.tgz -C /d .
```

## Deploy on a VPS without Docker

These steps assume Ubuntu or Debian with root access, and a domain name you control (e.g. `prayer.yourmasjid.org`). The app only talks to HTTPS servers, so you need a domain; Caddy below gets the certificate for you.

1. **Point the domain at the server.** Add a DNS `A` record for `prayer.yourmasjid.org` with your VPS's IP address.

2. **Install Node 22 and Caddy.**

   ```sh
   curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
   sudo apt-get install -y nodejs git
   sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
   sudo apt-get update && sudo apt-get install -y caddy
   node --version   # must be v22.13 or later
   ```

3. **Install the server.**

   ```sh
   sudo useradd --system --home /var/lib/snap-salat --shell /usr/sbin/nologin snapsalat
   sudo git clone https://github.com/meelash/snap-salat.git /opt/snap-salat
   sudo cp /opt/snap-salat/server/deploy/snap-salat.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now snap-salat
   ```

4. **Create your admin account.**

   ```sh
   cd /opt/snap-salat
   sudo -u snapsalat DATA_DIR=/var/lib/snap-salat node --disable-warning=ExperimentalWarning server/server.mjs create-admin admin
   ```

5. **Turn on HTTPS.** Copy `server/deploy/Caddyfile` to `/etc/caddy/Caddyfile` and replace the domain with yours. Then:

   ```sh
   sudo systemctl reload caddy
   ```

6. **Configure.** Open `https://prayer.yourmasjid.org/admin`, sign in, and set the masjid name, time zone, location and Maghrib rule.

7. **Firewall** (if `ufw` is on): allow only SSH and web traffic.

   ```sh
   sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp
   ```

   The Node server listens only on `127.0.0.1`, so Caddy is the only way in.

The address volunteers enter in the app is `https://prayer.yourmasjid.org/snap-salat`. To list the masjid in the app's directory, see [adding a masjid](../docs/adding-a-masjid.md).

### Updating

```sh
cd /opt/snap-salat && sudo git pull && sudo systemctl restart snap-salat
```

### Backups

Everything is in `/var/lib/snap-salat`: `snap-salat.db` and `photos/`. Copy that folder somewhere safe now and then. For a consistent copy of a live database:

```sh
sudo sqlite3 /var/lib/snap-salat/snap-salat.db ".backup /root/snap-salat-backup.db"
```

### Logs

```sh
journalctl -u snap-salat -f
```

## Showing the times on your website

The admin page's **Website widget** tab gives you the exact snippet. It's one line:

```html
<script src="https://prayer.yourmasjid.org/widget.js" async></script>
```

It renders where you put it, sizes itself, refreshes every 10 minutes, and its styles can't clash with your site's (it uses a shadow DOM). Options:

- `data-theme="light"` for a light version;
- `data-accent="#1E3A8A"` to change the accent colour;
- `data-adhan="1"` to also show adhan times;
- `data-target="#prayer-times"` to render inside an element that's already on your page.

If your site builder doesn't allow scripts, use an iframe:

```html
<iframe src="https://prayer.yourmasjid.org/widget" title="Prayer times"
        style="border:0;width:100%;max-width:420px;height:560px"></iframe>
```

To build your own design instead, read `https://prayer.yourmasjid.org/prayer-times.json`. It's open to any website (CORS):

```json
{
  "masjid": { "name": "Masjid Al-Noor", "timezone": "America/New_York" },
  "date": "2026-10-11",
  "iqamah": { "fajr": "06:15", "dhuhr": "13:30", "asr": "17:00", "maghrib": "18:24", "isha": "20:15", "jumuah": "13:45" },
  "adhan": {},
  "maghrib": { "source": "sunset", "sunset": "18:19", "offset_minutes": 5 },
  "captured_at": "2026-10-09T16:53:38-04:00",
  "updated_at": "2026-10-09T20:55:03.000Z"
}
```

## Announcing changes

The server can draft a "prayer times" post in the masjid's announcement
list (the bulletin-board app's `/api/v1`) whenever a volunteer's photo
changes the iqamah times. Turn it on under **Settings → Announcements**:
enter the list's address (e.g. `http://localhost:3000`) and an API key
(`bb_…`), then use **Save and test connection**.

Create the key in the announcement list with these scopes:

- **`posts:create`** to draft posts;
- **`posts:submit`** if drafts should go straight into the approval queue;
- **`posts:read`** so the admin page can show each post's status.

The connection test checks, without creating anything:

- that the key works;
- that the `prayer_times` template exists;
- that its `prayer-times` category exists and is active, since otherwise
  every post would be refused;
- whether the key can read posts.

A post is drafted only when both are true:

1. **A time really changed.** An iqamah time differs from the time already
   published. Two cases don't count:
   - a prayer being set for the first time, such as the very first upload;
   - Maghrib, while it's calculated from sunset, because the board's
     Maghrib clock is ignored then.
2. **The photo is later than the one behind the last announcement.** So a
   re-sent or out-of-order photo can never announce older times. (Photos
   older than the current times are already refused as stale.)

The request looks like this:

```http
POST {address}/api/v1/posts
Authorization: Bearer bb_…
Idempotency-Key: prayer-times-2026-11-02-3f9c1a2b7d

{
  "template": "prayer_times",
  "templateData": { "effectiveDate": "2026-11-02", "fajr": "6:00 AM", "dhuhr": "1:30 PM",
                    "asr": "4:00 PM", "maghrib": "Sunset + 5 min", "isha": "7:15 PM", "jumuah": "1:45 PM" },
  "bodyText": "Iqamah times change from Monday, November 2: Fajr 6:00 AM (was 6:15 AM), Isha 7:15 PM (was 7:30 PM).",
  "submit": true
}
```

- **`templateData`** carries all the current times, not only the changed
  ones. Maghrib reads "Sunset" or "Sunset + N min" when calculated.
- **`effectiveDate`** is the date of the photo.
- **`submit`** follows the *Submit each draft for approval* setting.
- **The idempotency key** is made from the date and the times. A retry can
  never create a second post, while a second, different change on the same
  day still gets its own post.

Sending happens in the background, so a slow or unavailable announcement
list never affects the volunteer. The admin **Overview** lists recent
announcements with each post's live status from `GET /api/v1/posts/<id>`
(draft → pending approval → approved → sent), and has a **Retry** button for
any that failed.

## Command line

| Command | What it does |
|---|---|
| `node server.mjs` | Runs the server |
| `node server.mjs create-admin <name>` | Creates an admin, or resets their password |
| `node server.mjs approve-user <name>` | Approves a volunteer without the web page |
| `node server.mjs list-users` | Lists volunteers and their status |

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | Port to listen on |
| `HOST` | `127.0.0.1` | Interface to listen on (keep it behind a proxy) |
| `DATA_DIR` | `./data` | Where the database and photos go |
| `INSECURE_COOKIES` | unset | `1` allows the admin cookie over plain http, for local testing only |
| `ADMIN_PASSWORD` | unset | Password for `create-admin`, instead of being asked |
