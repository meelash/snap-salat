import 'package:flutter/material.dart';
import 'package:snap_salat_api/snap_salat_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../main.dart';
import '../models/masjid.dart';
import 'sign_in_screen.dart';

/// Choose a masjid from the directory, or enter an endpoint by hand.
class MasjidPickerScreen extends StatelessWidget {
  const MasjidPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your masjid'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Directory'),
            Tab(text: 'Enter address'),
          ]),
        ),
        body: const TabBarView(children: [_Directory(), _ManualEntry()]),
      ),
    );
  }
}

Future<void> _choose(BuildContext context, Masjid m, {ServerInfo? info}) async {
  final state = AppScope.read(context);
  await state.selectMasjid(m, info: info);
  if (!context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  if (!state.signedIn) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SignInScreen()));
  }
}

/// Country → region → city → masjid, with search across everything.
class _Directory extends StatefulWidget {
  const _Directory();

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _path = <String>[]; // chosen country, region, city
  String _query = '';
  bool _refreshing = false;

  static String? _level(Masjid m, int depth) =>
      [m.country, m.region, m.city][depth];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final all = state.registry.masajid;
    final theme = Theme.of(context);

    Widget body;
    if (all.isEmpty) {
      body = _EmptyDirectory(refreshing: _refreshing);
    } else if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      final hits = all
          .where((m) => '${m.name} ${m.place}'.toLowerCase().contains(q))
          .toList();
      body = ListView(children: [
        for (final m in hits) _MasjidTile(m),
        if (hits.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No match. You can enter the address instead.'),
          ),
      ]);
    } else {
      final here = all.where((m) {
        for (var i = 0; i < _path.length; i++) {
          if (_level(m, i) != _path[i]) return false;
        }
        return true;
      }).toList();
      if (_path.length < 3) {
        final options = {
          for (final m in here) _level(m, _path.length) ?? 'Other'
        }.toList()
          ..sort();
        body = ListView(children: [
          for (final o in options)
            ListTile(
              title: Text(o),
              trailing: Text(
                  '${here.where((m) => (_level(m, _path.length) ?? 'Other') == o).length}',
                  style: theme.textTheme.bodySmall),
              onTap: () => setState(() => _path.add(o)),
            ),
        ]);
      } else {
        // Masajid in the city, grouped by area when there are several.
        here.sort((a, b) =>
            '${a.area ?? ''}${a.name}'.compareTo('${b.area ?? ''}${b.name}'));
        body = ListView(children: [for (final m in here) _MasjidTile(m)]);
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by name or city',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        if (_path.isNotEmpty && _query.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                      onPressed: () => setState(_path.clear),
                      child: const Text('All')),
                  for (var i = 0; i < _path.length; i++) ...[
                    const Icon(Icons.chevron_right, size: 16),
                    TextButton(
                      onPressed: () => setState(
                          () => _path.removeRange(i + 1, _path.length)),
                      child: Text(_path[i]),
                    ),
                  ],
                ],
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              setState(() => _refreshing = true);
              await state.registry.refresh();
              if (mounted) setState(() => _refreshing = false);
            },
            child: body,
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton(
              onPressed: () => launchUrl(AppConfig.addMasjidUrl),
              child: const Text('Masjid not listed? How to add it'),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyDirectory extends StatelessWidget {
  final bool refreshing;
  const _EmptyDirectory({required this.refreshing});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (refreshing) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          const Text(
            'No masajid in the directory yet. Pull down to refresh, or use '
            '“Enter address” if your masjid gave you one.',
            textAlign: TextAlign.center,
          ),
        ],
      );
}

class _MasjidTile extends StatelessWidget {
  final Masjid masjid;
  const _MasjidTile(this.masjid);

  @override
  Widget build(BuildContext context) {
    final selected = AppScope.of(context).masjid?.api == masjid.api;
    return ListTile(
      leading: const Icon(Icons.mosque_outlined),
      title: Text(masjid.name),
      subtitle: Text(masjid.place),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => _choose(context, masjid),
    );
  }
}

/// Type in the API address the masjid gave you.
class _ManualEntry extends StatefulWidget {
  const _ManualEntry();

  @override
  State<_ManualEntry> createState() => _ManualEntryState();
}

class _ManualEntryState extends State<_ManualEntry> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _connect() async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = SnapSalatApi.parseBaseUrl(_controller.text,
          allowInsecureLocal: state.allowInsecureLocal);
      final info = await SnapSalatApi(url).info();
      if (!mounted) return;
      await _choose(context, Masjid(name: info.masjidName, api: url),
          info: info);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'If your masjid’s website supports Snap Salat, they can give you '
          'its address. It usually looks like '
          'https://yourmasjid.org/snap-salat',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Address',
            hintText: 'https://…',
            border: const OutlineInputBorder(),
            errorText: _error,
            errorMaxLines: 3,
          ),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
      ],
    );
  }
}
