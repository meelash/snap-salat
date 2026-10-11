# Snap Salat app

The Flutter app for Android and iPhone. Volunteers photograph their masjid's
prayer-time board, check what was read, and send it to the masjid's server.

- User guide: <https://meelash.github.io/snap-salat/guide.html>
- The board reader lives in [`../packages/salat_reader`](../packages/salat_reader),
  and the API client in [`../packages/snap_salat_api`](../packages/snap_salat_api).

```sh
flutter test                 # widget tests
flutter run                  # on a connected device
flutter build apk --release  # Android (signed with the debug key until a release key is set up)
```

Debug builds may connect to `http://` servers on your own network for
testing (see `../server`). Release builds require `https://`.

Screenshots for the website are rendered with
`flutter test test/screenshots/render_screenshots.dart --update-goldens`.
