---
title: Add a masjid to the directory
permalink: /adding-a-masjid.html
---

# Add a masjid to the directory

The app has a built-in directory, so volunteers can pick their masjid instead
of typing an address. Entries are added through pull requests on GitHub.

**Before you start:** the masjid's website must implement the
[Snap Salat API](api.html). The directory only points the app at it.

## 1. Create one file

Make a JSON file at:

```
registry/masajid/<country>/<region>/<city>/<masjid-name>.json
```

Every part is lowercase, with hyphens instead of spaces:

- `<country>` is the 2-letter country code, e.g. `us`, `gb`, `pk`, `ca`.
- `<region>` is the state, province or region, e.g. `new-york`, `ontario`, `punjab`.
- `<city>` is e.g. `hamden`, `mississauga`, `lahore`.
- `<masjid-name>` is e.g. `masjid-al-noor`.

For example: `registry/masajid/us/connecticut/hamden/masjid-al-noor.json`

```json
{
  "$schema": "../../../../schema/masjid.schema.json",
  "name": "Masjid Al-Noor",
  "country": "US",
  "region": "Connecticut",
  "city": "Hamden",
  "area": "Whitneyville",
  "api": "https://masjidalnoor.org/snap-salat",
  "website": "https://masjidalnoor.org",
  "location": { "lat": 41.35, "lng": -72.9 },
  "display": {
    "type": "analog-clocks",
    "order": "rtl-rows",
    "sequence": ["fajr", "dhuhr", "asr", "maghrib", "isha", "jumuah"],
    "current_time_clock": true
  },
  "maintainers": ["your-github-username"]
}
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | As people know it. |
| `country` | yes | 2-letter code, **uppercase** here (`US`). |
| `region`, `city` | yes | Must match the folders (the folders are the lowercase, hyphenated form). |
| `area` | no | Neighbourhood, to tell apart masajid in a big city. |
| `api` | yes | The base URL of the API. Must start with `https://`. |
| `website` | no | The masjid's public site. |
| `location` | no | Latitude and longitude, for future "near me" sorting. |
| `display` | no | Hints that make reading the display more reliable. See below. |
| `maintainers` | no | GitHub usernames who may update this entry. |

### Display hints (optional)

If your masjid has an analog clock board, these tell the app which clock is
which, so it doesn't have to work it out:

- `type`: `"analog-clocks"` or `"text"` (printed, handwritten, LCD or screen).
- `order`: how the prayer clocks are read. `"rtl-rows"` means row by row,
  right to left, as on most Arabic and Urdu labelled boards. The others are
  `"ltr-rows"`, `"rtl-columns"` and `"ltr-columns"`.
- `sequence`: the prayers in that order.
- `current_time_clock`: `true` if there's a bigger clock showing the current
  time.

## 2. Check it

If you have Node.js 18 or later:

```sh
node tools/build-registry.mjs --check
```

If you don't, that's fine. The same check runs automatically on your pull
request.

## 3. Open a pull request

Describe your connection to the masjid (for example, "I maintain its
website"). We'll confirm that the API answers at `GET <api>/info` before
merging. After merging, the directory updates automatically and the app picks
it up the next time it refreshes.

To change or remove an entry, edit or delete the file in a new pull request.
