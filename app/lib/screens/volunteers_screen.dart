import 'package:flutter/material.dart';
import 'package:snap_salat_api/snap_salat_api.dart';

import '../main.dart';
import '../theme.dart';
import '../widgets/current_times_card.dart' show describeAge;

/// For the masjid's admins: approve or decline volunteers who registered
/// in the app, and revoke those who shouldn't send times any more.
class VolunteersScreen extends StatefulWidget {
  const VolunteersScreen({super.key});

  @override
  State<VolunteersScreen> createState() => _VolunteersScreenState();
}

class _VolunteersScreenState extends State<VolunteersScreen> {
  List<VolunteerAccount>? _all;
  String? _error;

  /// Volunteers with a decision being sent.
  final _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    final api = state.api, session = state.session;
    if (api == null || session == null) return;
    try {
      final all = await api.volunteers(session.accessToken);
      if (!mounted) return;
      setState(() {
        _all = all;
        _error = null;
      });
      state.setPendingCount(
          all.where((v) => v.status == VolunteerStatus.pending).length);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.needsSignIn) {
        await state.signOut();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() => _error = e.message);
    }
  }

  Future<void> _decide(VolunteerAccount v, VolunteerStatus to) async {
    final state = AppScope.read(context);
    if (to == VolunteerStatus.revoked && v.status == VolunteerStatus.approved) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Revoke ${v.name}?'),
          content: const Text(
              'They won’t be able to send prayer times any more. You can '
              'approve them again later.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Revoke')),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    setState(() => _busy.add(v.id));
    try {
      final token = state.session!.accessToken;
      final updated = to == VolunteerStatus.approved
          ? await state.api!.approve(token, v.id)
          : await state.api!.revoke(token, v.id);
      if (!mounted) return;
      setState(() {
        _all = [for (final x in _all!) x.id == v.id ? updated : x];
      });
      state.setPendingCount(
          _all!.where((x) => x.status == VolunteerStatus.pending).length);
      _snack(switch ((v.status, to)) {
        (_, VolunteerStatus.approved) => '${v.name} can now send times.',
        (VolunteerStatus.pending, _) => '${v.name}’s request was declined.',
        _ => '${v.name} can no longer send times.',
      });
    } on ApiException catch (e) {
      _snack(e.message);
      if (e.status == 404) _load();
    } finally {
      if (mounted) setState(() => _busy.remove(v.id));
    }
  }

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    List<VolunteerAccount> of(VolunteerStatus s) =>
        all?.where((v) => v.status == s).toList() ?? const [];
    final pending = of(VolunteerStatus.pending);
    final approved = of(VolunteerStatus.approved);
    final revoked = of(VolunteerStatus.revoked);

    return Scaffold(
      appBar: AppBar(title: const Text('Volunteers')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                    Text(_error!, style: const TextStyle(color: Brand.error)),
              )
            else if (all == null)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              const _Section('WAITING FOR APPROVAL'),
              if (pending.isEmpty)
                const _Empty('No one is waiting.')
              else
                for (final v in pending)
                  _VolunteerCard(v, busy: _busy.contains(v.id), actions: [
                    (
                      'Approve',
                      true,
                      () => _decide(v, VolunteerStatus.approved)
                    ),
                    (
                      'Decline',
                      false,
                      () => _decide(v, VolunteerStatus.revoked)
                    ),
                  ]),
              const _Section('CAN SEND TIMES'),
              if (approved.isEmpty)
                const _Empty('No approved volunteers yet.')
              else
                for (final v in approved)
                  _VolunteerCard(v, busy: _busy.contains(v.id), actions: [
                    (
                      'Revoke',
                      false,
                      () => _decide(v, VolunteerStatus.revoked)
                    ),
                  ]),
              if (revoked.isNotEmpty) ...[
                const _Section('REVOKED OR DECLINED'),
                for (final v in revoked)
                  _VolunteerCard(v, busy: _busy.contains(v.id), actions: [
                    (
                      'Approve',
                      false,
                      () => _decide(v, VolunteerStatus.approved)
                    ),
                  ]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 10),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Brand.brass)),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 15, color: Brand.muted));
}

class _VolunteerCard extends StatelessWidget {
  final VolunteerAccount v;
  final bool busy;

  /// Label, primary?, action.
  final List<(String, bool, VoidCallback)> actions;
  const _VolunteerCard(this.v, {required this.busy, required this.actions});

  @override
  Widget build(BuildContext context) {
    final registered = v.registeredAt?.toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(v.name,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                [
                  v.username,
                  if (v.contact != null && v.contact!.isNotEmpty) v.contact!,
                ].join(' · '),
                style: const TextStyle(fontSize: 14, color: Brand.muted),
              ),
              if (v.note != null && v.note!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('“${v.note}”', style: const TextStyle(fontSize: 15)),
              ],
              if (registered != null) ...[
                const SizedBox(height: 6),
                Text('Registered ${describeAge(registered)}',
                    style: const TextStyle(fontSize: 13, color: Brand.muted)),
              ],
              const SizedBox(height: 12),
              if (busy)
                const SizedBox(
                    height: 44, child: Center(child: LinearProgressIndicator()))
              else
                Row(
                  children: [
                    for (final (label, primary, onPressed) in actions) ...[
                      Expanded(
                        child: primary
                            ? FilledButton(
                                style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(44)),
                                onPressed: onPressed,
                                child: Text(label))
                            : OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(44)),
                                onPressed: onPressed,
                                child: Text(label)),
                      ),
                      if (label != actions.last.$1) const SizedBox(width: 10),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
