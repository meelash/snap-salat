/// Where the app finds things on the web. Change these if you fork.
class AppConfig {
  /// The masjid directory, built from registry/ by tools/build-registry.mjs.
  static final registryUrl = Uri.parse(
      'https://raw.githubusercontent.com/meelash/snap-salat/main/registry/index.json');

  /// User guide (GitHub Pages).
  static final helpUrl = Uri.parse('https://meelash.github.io/snap-salat/');

  /// How to add a masjid to the directory.
  static final addMasjidUrl =
      Uri.parse('https://meelash.github.io/snap-salat/adding-a-masjid.html');

  /// The "display not read well" issue form, prefilled (GitHub issue forms
  /// take field values as query parameters named by field id).
  static Uri reportDisplayUrl({String? kind, String? truth, String? notes}) =>
      Uri.https('github.com', '/meelash/snap-salat/issues/new', {
        'template': 'new-display.yml',
        'title': 'Display not read well',
        if (kind != null) 'kind': kind,
        if (truth != null) 'truth': truth,
        if (notes != null) 'notes': notes,
      });
}
