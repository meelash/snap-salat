# Snap Salat

Update your masjid's online prayer times by taking a photo of its display.

A volunteer photographs the prayer-time board. The app reads the times on the
phone, the volunteer checks them, and the app sends them, together with the
time the photo was taken, to the masjid's website through a small,
documented API.

🌐 **Website: <https://meelash.github.io/snap-salat/>**: user guide, the example server, the API, and how it all works.

| | |
|---|---|
| **For volunteers** | [How to use the app](https://meelash.github.io/snap-salat/) |
| **For masjid websites** | [API specification](docs/api.md) · [OpenAPI](docs/openapi.yaml) · [example server](server/) you can deploy as is |
| **To list a masjid in the app** | [Add it to the directory](docs/adding-a-masjid.md) with a pull request |
| **Display not read well?** | Tap *Share this photo* on the review screen, or [share a sample photo](https://github.com/meelash/snap-salat/issues/new?template=new-display.yml) |

## Using the app

1. **Choose your masjid** from the built-in directory (country → region → city),
   or enter the API address your masjid gave you.
2. **Register** as a volunteer in the app (or sign in if you already have an
   account). Someone at the masjid approves you before you can send times.
3. **Take a photo** of the display (straight on, no glare), or choose an
   existing one.
4. **Check the times.** Each one is outlined on the photo: green means
   confident, orange means please check, red means enter it by hand. Tap
   any time to fix it. The photo's time can't be changed.
5. **Send.** The masjid's site receives the times, the photo's timestamp, and
   the reading of the board's own clock if it has one.

### Displays it reads

- **Analog clock boards** (one clock per prayer, often with a big current-time
  clock), like the board in [`sample_images/`](sample_images/). The app finds
  each dial, reads its hands, works out AM/PM and which clock is which prayer,
  and checks the current-time clock against the photo's timestamp.
- **Printed, handwritten and on-screen timetables**, using on-device text
  recognition. Prayer names can be in English transliteration or Arabic, in
  rows or columns, with or without separate adhan and iqamah columns.
- **LCD digits:** partly. **Arabic-Indic digits:** not yet.

You can always type or correct times on the review screen.

## For masjid websites (API in brief)

Implement these under any HTTPS base URL, e.g. `https://yourmasjid.org/snap-salat`:

| Endpoint | Purpose |
|---|---|
| `GET /info` | `{"api": "snap-salat", "version": 1, "masjid": {...}, "auth": {"methods": ["password"], "register": true}}` |
| `POST /auth/register` | A volunteer asks for an account; it starts `pending` |
| `POST /auth/login` | Username and password in, `{"access_token": ..., "user": {"status": ...}}` out |
| `GET /auth/check` | Token still valid? Volunteer `pending`, `approved` or `revoked`? |
| `POST /prayer-times` | Bearer-authenticated. Receives `captured_at`, `captured_at_source`, `date`, `iqamah` (incl. `jumuah`), optional `adhan`, `display_clock`, … |
| `GET /prayer-times` | Optional. Current times |

Times are 24-hour `HH:MM` local to the masjid. `captured_at` is the ISO 8601
time the photo was taken, with UTC offset. Use it to reject photos that are
stale (`409`) or too old (`422`). The full contract, with examples and
validation rules, is in **[docs/api.md](docs/api.md)**.

Only approved volunteers may send times (`403 not_approved` otherwise).

### The example server

[`server/`](server/) implements all of this with no dependencies (Node 22.13+,
SQLite built in), and is meant to be deployed for real:

- an **admin page** to approve or revoke volunteers, review each update with
  its photo, and set Maghrib to follow the board or to be calculated from
  sunset (plus an offset);
- **public prayer times** as JSON and as a styled **widget** for the
  masjid's website, added with one line of HTML (or an iframe).

Its [README](server/README.md) covers running it locally and deploying it
on a small VPS behind Caddy (automatic HTTPS) with systemd.

## Repository layout

```
app/                    Flutter app (Android + iOS)
packages/salat_reader/  Pure-Dart display reader: analog clock boards + OCR-text parser
packages/snap_salat_api/  Pure-Dart API client
server/                 Example server: API, admin page, website widget (Node, no dependencies) + tests
registry/               Masjid directory: one JSON file per masjid, schema, built index.json
tools/                  build-registry.mjs (validates entries, builds the index)
docs/                   The website (GitHub Pages): user guide, example server, API spec, OpenAPI, directory, how it works
sample_images/          Real photos used as test fixtures
```

### How the analog reader works

All of it is in [`packages/salat_reader/lib/src/analog/`](packages/salat_reader/lib/src/analog/):

1. **Find dials.** A gradient Hough transform with banded accumulators finds
   clocks even when they appear as ellipses at an angle. Each candidate is
   refined by casting rays to the rim and robustly fitting an ellipse.
   Brightness thresholds aren't used, because glass reflections defeat them.
2. **Read hands.** Each dial is resampled into a canonical circle, which also
   undoes mild perspective. A black top-hat filter isolates thin dark strokes
   regardless of glare. Hands are found as dark runs reaching out from the
   hub. Each hand's centre line is fitted from darkness-weighted
   cross-sections, which handles hollow hands and their shadows, and the
   pivot is refined from where the hand lines cross.
3. **Decide which hand is which.** Score both role assignments: the hour
   hand must sit where the minute hand says it should, minute hands are
   longer, and hour hands are wider. Overlapping hands are a separate
   hypothesis. Close calls are kept as alternatives.
4. **Label the board.** Try each reading order (right-to-left or
   left-to-right, rows or columns) and keep the one where every prayer falls
   in its usual window and the day runs in order. That window also settles
   close calls from step 3. Registry entries can state the layout explicitly.

Readings it isn't sure of are flagged for the user rather than guessed
silently.

## Development

```sh
# Reader and API client (pure Dart)
cd packages/salat_reader && dart test     # includes the real sample photo and randomized synthetic boards
cd packages/snap_salat_api && dart test

# Reference server and directory tooling (Node 18+)
(cd server && npm test)
node --test tools/build-registry.test.mjs
node tools/build-registry.mjs              # rebuild registry/index.json + app/assets/registry.json

# App
cd app && flutter test && flutter run
```

Useful while improving the reader:

```sh
cd packages/salat_reader
dart run bin/read_board.dart photo.jpg --debug    # JSON reading + diagnostics
dart run bin/debug_hands.dart photo.jpg out/      # per-clock crops with detected hands drawn
dart run tool/synthetic_eval.dart 40 7            # accuracy over 40 random synthetic boards
```

When adding a new sample photo, put it in `sample_images/` with a test that
states the true times, as in `test/analog_sample_test.dart`.

### Configuration if you fork

The directory URL, help links and package id are in
[`app/lib/config.dart`](app/lib/config.dart) and the Android/iOS project
files (`org.snapsalat.snap_salat`).
