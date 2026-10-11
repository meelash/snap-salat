---
title: How it works
description: How Snap Salat reads prayer-time boards, how the project is put together, and how to contribute.
---

# How it works

Everything lives in [one repository](https://github.com/meelash/snap-salat):

| Part | What it is |
|---|---|
| [`app/`](https://github.com/meelash/snap-salat/tree/main/app) | The phone app for Android and iPhone, built with Flutter |
| [`packages/salat_reader/`](https://github.com/meelash/snap-salat/tree/main/packages/salat_reader) | The board reader: pure Dart, runs on the phone and in plain `dart test` |
| [`packages/snap_salat_api/`](https://github.com/meelash/snap-salat/tree/main/packages/snap_salat_api) | The API client: pure Dart |
| [`server/`](https://github.com/meelash/snap-salat/tree/main/server) | The [example server](server.html): API, admin page, widget, announcements |
| [`registry/`](https://github.com/meelash/snap-salat/tree/main/registry) | The masjid [directory](adding-a-masjid.html): one JSON file per masjid |
| [`docs/`](https://github.com/meelash/snap-salat/tree/main/docs) | This website |

## Reading an analog clock board

Boards like this one are the hardest case: up to seven clocks behind
reflective glass, with no machine-readable labels. The reader runs entirely on
the phone, in a background isolate, in about two seconds.

**1. Find the dials.** Brightness thresholds fail on these boards, because
glass reflects windows and lights. So the reader uses edges. Every strong
edge votes for possible circle centres along its gradient, a *Hough
transform*. Votes are kept in separate accumulators per range of sizes, whose
cells grow with the radius, so a big clock seen at an angle (an ellipse) still
forms one clear peak. For each peak, rays are cast outward to find the rim,
and an ellipse is fitted to those points, discarding outliers. A candidate is
kept only if:

- enough of the rim agrees with the fitted ellipse;
- the inside is brighter than the surround;
- the outer ring has the texture of numerals or tick marks.

**2. Read the hands.**

- Each dial is resampled into a canonical circle, which also undoes mild
  perspective.
- A *black top-hat* filter (morphological closing minus the image) picks out
  thin dark strokes whatever the local brightness, so glare and reflections
  matter far less.
- Hands are dark runs that reach out from the hub; numerals and logos aren't
  connected to it.
- Each hand's centre line is fitted from darkness-weighted cross-sections.
  This finds the axis of solid and hollow ("skeleton") hands alike, and isn't
  pulled sideways by the hand's paler shadow on the dial.
- The pivot is refined from where the hand lines cross.

**3. Decide which hand is which.** Both readings of each pair of hands are
scored together, using three cues:

- the hour hand must sit where the minute hand says it should (σ ≈ 5°, since
  cheap movements are often a few degrees off);
- minute hands are longer;
- hour hands are wider.

Overlapping hands are a separate hypothesis. Near-overlaps are read from the
streak's tip (the minute hand alone) and its inner part (both hands). A hand
that disappears into blown-out glare has its length treated as a lower bound,
not a measurement.

**4. Label the board.** The reader tries each reading order (rows or columns,
right to left or left to right). It keeps the one where every prayer falls in
its usual window and the day runs in order. Close calls from step 3 are
settled here too, by which reading fits the prayer's usual time. A directory
entry can state the layout instead.

**5. Check the photo is fresh.** A clearly bigger clock is the current-time
clock. Its reading is compared with the photo's timestamp and sent to the
masjid.

Anything the reader isn't sure of is **flagged for the volunteer, never
silently guessed**. On randomised synthetic boards (hollow and solid hands,
shadows, glare, camera tilt, perspective, noise), about 95% of clocks read
within a minute, and almost every wrong reading is flagged.

## Reading text boards

Printed, written and on-screen timetables are read with Google ML Kit's
on-device text recognition. The words and times it finds are then matched up
by their positions:

- prayer names in English transliterations (Fajr, Zuhr, Dhuhr…) or Arabic;
- times like `5:45`, `05:45 AM` or `17:45`, correcting common LCD look-alikes
  (O→0, l→1, S→5, B→8);
- "Adhan/Begins" and "Iqamah/Jamaat" column headers.

It handles boards laid out in rows or in columns.

## Development

```sh
# Reader and API client (pure Dart)
cd packages/salat_reader && dart test     # the real sample photo + randomised synthetic boards
cd packages/snap_salat_api && dart test   # includes the client against the example server

# Server and directory tooling (Node 22.13+)
cd server && npm test
node --test tools/build-registry.test.mjs

# App
cd app && flutter test && flutter run
```

Useful when improving the reader:

```sh
cd packages/salat_reader
dart run bin/read_board.dart photo.jpg --debug    # the reading as JSON, plus diagnostics
dart run bin/debug_hands.dart photo.jpg out/      # per-clock crops with the detected hands drawn
dart run tool/synthetic_eval.dart 40 7            # accuracy over 40 random synthetic boards
```

## Contributing

- **Share photos of boards the app reads badly.** Use the app's *Share this
  photo* button, or [open the form](https://github.com/meelash/snap-salat/issues/new?template=new-display.yml).
  Each one becomes a test case with its true times, in `sample_images/`.
- **Add your masjid to the directory** with a [one-file pull request](adding-a-masjid.html).
- **Implement the [API](api.html)** on your masjid's website, or run the
  [example server](server.html).
