import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:salat_reader/salat_reader.dart';
import 'package:snap_salat_api/snap_salat_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

import '../main.dart';
import '../services/recognition.dart';
import '../theme.dart';
import '../widgets/board_overlay.dart';
import 'sign_in_screen.dart';

const _appVersion = '1.0.0';

/// Reads the photo, lets the user check and fix every time, then sends.
class ReviewScreen extends StatefulWidget {
  final PhotoInput photo;

  /// A reading already made (screenshots, tests); otherwise the photo is
  /// read when the screen opens.
  final RecognitionResult? initialResult;

  const ReviewScreen({super.key, required this.photo, this.initialResult});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

/// One editable time on the form.
class _Entry {
  Hm? time;
  double confidence;
  bool edited = false;
  bool missing;
  _Entry(this.time, this.confidence, {this.missing = false});
}

class _ReviewScreenState extends State<ReviewScreen> {
  ReaderChoice _choice = ReaderChoice.auto;
  RecognitionResult? _result;
  String? _error;
  bool _sending = false;

  /// When the photo was taken. Deliberately not editable, so it can't be
  /// faked in the app (see docs/api.md).
  late CaptureInfo _capture;

  // Form state, keyed by prayer. Jumu'ah is one iqamah time like the rest.
  final _iqamah = <Prayer, _Entry>{};

  /// Start times, only when the display itself shows them (text boards
  /// with an adhan/begins column).
  final _adhan = <Prayer, _Entry>{};

  static const _iqamahPrayers = [...Prayer.daily, Prayer.jumuah];

  @override
  void initState() {
    super.initState();
    _capture = captureInfoFor(widget.photo);
    final given = widget.initialResult;
    if (given != null) {
      _result = given;
      _capture = given.capture;
      _fillForm(given.reading);
    } else {
      _read();
    }
  }

  Future<void> _read() async {
    setState(() {
      _result = null;
      _error = null;
    });
    try {
      final hints = AppScope.read(context).masjid?.display;
      final r = await recognise(widget.photo, hints: hints, choice: _choice);
      if (!mounted) return;
      setState(() {
        _result = r;
        _capture = r.capture;
        _fillForm(r.reading);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read the photo: $e');
    }
  }

  void _fillForm(BoardReading reading) {
    _iqamah.clear();
    _adhan.clear();
    for (final t in reading.times) {
      final p = t.prayer;
      if (p == null) continue;
      final target = t.kind == TimeKind.adhan ? _adhan : _iqamah;
      target.putIfAbsent(p, () => _Entry(t.time, t.confidence));
    }
    for (final m in reading.missing) {
      final p = m.prayer;
      if (p == null) continue;
      _iqamah.putIfAbsent(p, () => _Entry(null, 0, missing: true));
    }
  }

  Future<void> _pickTime(_Entry entry, String label) async {
    final initial = entry.time ?? const Hm(12, 0);
    final picked = await showTimePicker(
      context: context,
      helpText: label,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    );
    if (picked == null) return;
    setState(() {
      entry.time = Hm(picked.hour, picked.minute);
      entry.edited = true;
      entry.confidence = 1;
      entry.missing = false;
    });
  }

  /// Unlabelled readings can be assigned to a prayer by tapping them.
  Future<void> _assign(TimeReading t) async {
    final p = await showDialog<Prayer>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Which prayer is ${t.time.to12h()}?'),
        children: [
          for (final p in Prayer.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.displayName),
            ),
        ],
      ),
    );
    if (p == null) return;
    final m = to24h(p, t.time.inMinutes % 720);
    setState(() {
      final e = _Entry(Hm.fromMinutes(m), t.confidence)..edited = true;
      (p == Prayer.sunrise ? _adhan : _iqamah)[p] = e;
      t.prayer = p;
    });
  }

  Map<String, String> _wire(Map<Prayer, _Entry> m) => {
        for (final e in m.entries)
          if (e.value.time != null) e.key.name: e.value.time.toString()
      };

  List<String> get _editedKeys => [
        for (final e in _iqamah.entries)
          if (e.value.edited) e.key.name,
        for (final e in _adhan.entries)
          if (e.value.edited) '${e.key.name}_adhan',
      ];

  Future<void> _send() async {
    final state = AppScope.read(context);
    final result = _result!;
    if (!state.signedIn) {
      final ok = await Navigator.of(context)
          .push<bool>(MaterialPageRoute(builder: (_) => const SignInScreen()));
      if (ok != true || !mounted) return;
    }
    // Only volunteers the masjid has approved may send times.
    final status = await state.refreshStatus();
    if (!mounted) return;
    if (status == VolunteerStatus.pending ||
        status == VolunteerStatus.revoked) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.hourglass_top),
          title: Text(status == VolunteerStatus.pending
              ? 'Waiting for approval'
              : 'Not allowed to send'),
          content: Text(status == VolunteerStatus.pending
              ? '${state.masjid!.name} hasn’t approved your account yet. '
                  'Once they do, open this photo again and send it, if it’s '
                  'still recent.'
              : 'Your permission to update ${state.masjid!.name}’s times '
                  'has been removed. Please ask the masjid.'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final info = state.serverInfo ?? await state.refreshServerInfo();
    if (!mounted) return;

    final iqamah = _wire(_iqamah);
    final adhan =
        (info?.acceptsAdhan ?? true) ? _wire(_adhan) : <String, String>{};
    if (iqamah.isEmpty && adhan.isEmpty) {
      _snack('There are no times to send yet.');
      return;
    }

    final ageHours = _capture.age.inMinutes / 60;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send to ${state.masjid!.name}?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in iqamah.entries)
                Text('${_name(e.key)}: ${Hm.tryParse(e.value)!.to12h()}'),
              if (adhan.isNotEmpty) Text('+ ${adhan.length} adhan times'),
              const SizedBox(height: 12),
              Text('Photo taken ${_formatCapture(_capture)}'),
              if (ageHours > 24)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'This photo is ${ageHours ~/ 24} day(s) old. '
                    'The masjid may reject it.',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    try {
      final submission = PrayerTimesSubmission(
        capturedAt: _capture.iso,
        capturedAtSource: _capture.source,
        date: _capture.date,
        iqamah: iqamah,
        adhan: adhan,
        displayClock: result.reading.displayClock?.time.toString(),
        recognition: {
          'reader': result.reading.reader,
          'confidence':
              double.parse(result.reading.confidence.toStringAsFixed(2)),
          'edited': _editedKeys,
          if (result.reading.warnings.isNotEmpty)
            'warnings': result.reading.warnings,
        },
        client: {
          'app': 'snap-salat',
          'version': _appVersion,
          'platform': Platform.operatingSystem,
        },
        imageSha256: result.imageSha256,
        imageJpegBase64: info?.acceptsImage == true
            ? await photoForUpload(widget.photo.bytes)
            : null,
      );
      SubmitResult sent;
      try {
        sent = await state.api!.submit(state.session!.accessToken, submission);
      } on ApiException catch (e) {
        if (!e.needsSignIn || !mounted) rethrow;
        // Token expired: sign in again and retry once.
        await state.signOut();
        if (!mounted) return;
        final ok = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const SignInScreen()));
        if (ok != true) return;
        sent = await state.api!.submit(state.session!.accessToken, submission);
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline),
          title: const Text('Sent'),
          content: Text(sent.message ??
              '${state.masjid!.name} now has the new prayer times.'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (e.notApproved) state.refreshStatus();
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _name(String key) =>
      Prayer.values.firstWhere((p) => p.name == key).displayName;

  static String _formatCapture(CaptureInfo c) {
    final t = Hm(c.local.hour, c.local.minute).to12h();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[c.local.month - 1]} ${c.local.day}, $t';
  }

  static String _captureSource(String s) => switch (s) {
        'exif' => 'Recorded by the camera · can’t be changed',
        'camera' => 'Taken just now · can’t be changed',
        'file' => 'From the file’s date (no camera data) · can’t be changed',
        _ => 'Can’t be changed',
      };

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check the times'),
        actions: [
          PopupMenuButton<ReaderChoice>(
            tooltip: 'Display type',
            icon: const Icon(Icons.tune),
            initialValue: _choice,
            onSelected: (c) {
              _choice = c;
              _read();
            },
            itemBuilder: (_) => [
              for (final c in ReaderChoice.values)
                PopupMenuItem(value: c, child: Text('Read as: ${c.label}')),
            ],
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(24), child: Text(_error!)))
          : result == null
              ? const Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Reading the display…'),
                  ],
                ))
              : _form(context, result),
      bottomNavigationBar: result == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(60)),
                  onPressed: _sending ? null : _send,
                  child: _sending
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Text(
                          'Send to ${AppScope.of(context).masjid?.name ?? 'masjid'}',
                          overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
    );
  }

  Widget _form(BuildContext context, RecognitionResult result) {
    final reading = result.reading;
    final unassigned = reading.unlabelled.toList();
    final displayClock = reading.displayClock;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BoardOverlay(bytes: widget.photo.bytes, reading: reading),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoLine(
                icon: Icons.lock_outline,
                children: [
                  const TextSpan(text: 'Photo taken '),
                  TextSpan(
                      text: _formatCapture(_capture),
                      style: const TextStyle(
                          color: Brand.text, fontWeight: FontWeight.w700)),
                  TextSpan(text: ' · ${_captureSource(_capture.source)}'),
                ],
              ),
              if (displayClock != null) ...[
                const SizedBox(height: 10),
                _InfoLine(
                  icon: Icons.schedule,
                  iconColor: Brand.ok,
                  children: [
                    const TextSpan(text: 'Board clock shows '),
                    TextSpan(
                        text: displayClock.time.to12h(),
                        style: const TextStyle(
                            color: Brand.text, fontWeight: FontWeight.w700)),
                    const TextSpan(
                        text:
                            ', sent so the masjid can see the photo is fresh'),
                  ],
                ),
              ],
            ],
          ),
        ),
        for (final w in reading.warnings)
          _Banner(icon: Icons.info_outline, text: w),
        if (reading.times.isEmpty)
          const _Banner(
            icon: Icons.help_outline,
            text: 'No times were read. Try another photo (straight on, no '
                'glare), choose a display type with the button at the top, '
                'or enter the times below.',
          ),
        if (unassigned.isNotEmpty) ...[
          const _Header('Couldn’t tell which prayer these are',
              hint: 'Tap to assign'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in unassigned)
                ActionChip(
                    label: Text(t.time.to12h()), onPressed: () => _assign(t)),
            ]),
          ),
        ],
        const _Header('IQAMAH', hint: 'Tap to change · hold to clear'),
        _tiles([
          for (final p in _iqamahPrayers)
            (p, _iqamah.putIfAbsent(p, () => _Entry(null, 1))),
        ]),
        if (_adhan.isNotEmpty) ...[
          const _Header('ADHAN', hint: 'Start times shown on the display'),
          _tiles([
            for (final p in Prayer.values)
              if (_adhan[p] != null) (p, _adhan[p]!),
          ]),
        ],
        const SizedBox(height: 16),
        _reportOption(reading),
      ],
    );
  }

  /// Offer to share the photo when the reading went wrong: prominently if
  /// the user had to correct or fill in times, quietly otherwise.
  Widget _reportOption(BoardReading reading) {
    final struggled = reading.times.isEmpty ||
        reading.missing.isNotEmpty ||
        _editedKeys.isNotEmpty;
    if (!struggled) {
      return Center(
        child: TextButton(
          onPressed: () => _report(reading),
          child: const Text('Didn’t read the display right? Share this photo'),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Help the app read this display',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('You had to fix some times. Sharing this photo, with '
                'the correct times, is how the app learns new displays.'),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.ios_share),
              label: const Text('Share this photo'),
              onPressed: () => _report(reading),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _report(BoardReading reading) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share this photo'),
        content: const Text(
            'This opens a form on GitHub (you’ll need a free account), '
            'already filled in with what the app read and your corrections. '
            'Attach this photo there, then submit.\n\n'
            'Only share photos of displays in public areas of the masjid.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open form')),
        ],
      ),
    );
    if (go != true) return;
    String list(Map<Prayer, _Entry> m) => [
          for (final p in Prayer.values)
            if (m[p]?.time != null) '${p.displayName} ${m[p]!.time!.to12h()}'
        ].join(', ');
    final read = [
      for (final t in reading.times)
        if (t.prayer != null)
          '${t.prayer!.displayName} ${t.time.to12h()} '
              '(${(t.confidence * 100).round()}%)'
    ].join(', ');
    await launchUrl(
      AppConfig.reportDisplayUrl(
        kind: reading.reader == 'analog-clocks'
            ? 'Analog clocks (one per prayer)'
            : null,
        truth: [
          list(_iqamah),
          if (_adhan.isNotEmpty) 'Adhan: ${list(_adhan)}',
        ].join('\n'),
        notes: 'App read: ${read.isEmpty ? 'nothing' : read}\n'
            'Couldn’t read: ${reading.missing.length}\n'
            'Corrected: ${_editedKeys.isEmpty ? 'none' : _editedKeys.join(', ')}\n'
            'Reader: ${reading.reader} · app $_appVersion · '
            '${Platform.operatingSystem}',
      ),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Prayer tiles, two per row, numbered like the pins on the photo.
  Widget _tiles(List<(Prayer, _Entry)> items) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _tile(items[i].$1, items[i].$2)),
          const SizedBox(width: 10),
          Expanded(
              child: i + 1 < items.length
                  ? _tile(items[i + 1].$1, items[i + 1].$2)
                  : const SizedBox()),
        ],
      ));
      if (i + 2 < items.length) rows.add(const SizedBox(height: 10));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(children: rows),
    );
  }

  Widget _tile(Prayer p, _Entry e) {
    final unsure = e.time != null && e.confidence < 0.8 && !e.edited;
    final accent =
        e.missing ? Brand.error : (unsure ? Brand.check : Brand.brass);
    final number = prayerNumber(p);
    final time = e.time;
    return Semantics(
      button: true,
      label: '${p.displayName}, ${time?.to12h() ?? 'not set'}'
          '${unsure ? ', please check' : ''}',
      child: Material(
        color: unsure || e.missing ? Brand.checkSurface : Brand.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: unsure || e.missing
              ? BorderSide(color: accent, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _pickTime(e, p.displayName),
          onLongPress: time == null
              ? null
              : () {
                  setState(() {
                    e.time = null;
                    e.edited = true;
                  });
                  _snack('${p.displayName} cleared. It won’t be sent.');
                },
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${number == null ? '' : '$number · '}${p.displayName}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color:
                                  unsure || e.missing ? accent : Brand.muted),
                        ),
                      ),
                      Text(arabicPrayerNames[p.name] ?? '',
                          textDirection: TextDirection.rtl,
                          style: TextStyle(
                              fontFamily: Brand.arabicFont,
                              fontSize: 18,
                              color: accent)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (time != null)
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: time.to12h().split(' ').first,
                            style: const TextStyle(fontSize: 30)),
                        TextSpan(
                            text: ' ${time.to12h().split(' ').last}',
                            style: const TextStyle(fontSize: 14)),
                      ]),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    )
                  else
                    Text(e.missing ? 'Tap to enter' : 'Not set',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: e.missing ? Brand.error : Brand.muted)),
                  if (unsure) ...[
                    const SizedBox(height: 4),
                    const Text('Please check',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Brand.check)),
                  ],
                  if (e.missing && time == null) ...[
                    const SizedBox(height: 4),
                    const Text('Couldn’t read this clock',
                        style: TextStyle(fontSize: 13, color: Brand.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final List<InlineSpan> children;
  const _InfoLine(
      {required this.icon,
      this.iconColor = Brand.muted,
      required this.children});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: children),
                style: const TextStyle(fontSize: 14, color: Brand.muted)),
          ),
        ],
      );
}

class _Header extends StatelessWidget {
  final String text;
  final String? hint;
  const _Header(this.text, {this.hint});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(text,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Brand.brass)),
            if (hint != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(hint!,
                    style: const TextStyle(fontSize: 14, color: Brand.muted)),
              ),
            ],
          ],
        ),
      );
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Brand.outline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Brand.brass),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
