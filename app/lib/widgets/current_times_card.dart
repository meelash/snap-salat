import 'package:flutter/material.dart';
import 'package:salat_reader/salat_reader.dart';

import '../main.dart';
import '../theme.dart';

/// "On the website now": the times the masjid publishes, and how old the
/// photo behind them is, so a volunteer can tell whether they need updating.
class CurrentTimesCard extends StatelessWidget {
  const CurrentTimesCard({super.key});

  static const _iqamah = [...Prayer.daily, Prayer.jumuah];

  /// Times from a photo older than this are probably out of date.
  static const staleAfter = Duration(days: 7);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final current = state.current;

    Widget body;
    if (current == null && !state.currentLoaded) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    } else if (current == null) {
      body = const Text(
          'This masjid’s server doesn’t share its current times with the app.',
          style: TextStyle(fontSize: 14, color: Brand.muted));
    } else if (current.isEmpty) {
      body = const Text('No times yet. Yours will be the first.',
          style: TextStyle(fontSize: 14, color: Brand.muted));
    } else {
      final taken = current.capturedTime?.toLocal();
      final age = taken == null ? null : DateTime.now().difference(taken);
      final stale = age != null && age > staleAfter;
      final adhan = [
        for (final p in Prayer.values)
          if (Hm.tryParse(current.adhan[p.name] ?? '') case final Hm t)
            '${p.displayName} ${t.to12h()}'
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Three to a row, like the board.
          LayoutBuilder(
            builder: (context, c) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _iqamah)
                  SizedBox(
                    width: (c.maxWidth - 16) / 3,
                    child: _TimeChip(
                      p,
                      Hm.tryParse(current.iqamah[p.name] ?? ''),
                      note: p == Prayer.maghrib && current.maghribFromSunset
                          ? 'sunset'
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          if (adhan.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Adhan: ${adhan.join(' · ')}',
                style: const TextStyle(fontSize: 13, color: Brand.muted)),
          ],
          if (taken != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(stale ? Icons.history : Icons.photo_camera_outlined,
                    size: 18, color: stale ? Brand.check : Brand.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'From a photo taken ${describeAge(taken)}'
                    '${stale ? '. It may need updating.' : '.'}',
                    style: TextStyle(
                        fontSize: 14,
                        color: stale ? Brand.check : Brand.muted,
                        fontWeight: stale ? FontWeight.w600 : null),
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }

    return Material(
      color: Brand.surface,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('ON THE WEBSITE NOW',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          color: Brand.brass)),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: state.refreshCurrent,
                ),
              ],
            ),
            Padding(padding: const EdgeInsets.only(right: 10), child: body),
            if (state.canNotify) ...[
              const SizedBox(height: 6),
              const Divider(height: 1, color: Brand.outline),
              SwitchListTile(
                contentPadding: const EdgeInsets.only(right: 4),
                title: const Text('Notify me when these times change',
                    style: TextStyle(fontSize: 15)),
                value: state.followsTimes,
                onChanged: (v) async {
                  final ok = await state.setFollowTimes(v);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Notifications aren’t allowed for '
                            'Snap Salat. Turn them on in your phone’s '
                            'settings.')));
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimeChip extends StatelessWidget {
  final Prayer prayer;
  final Hm? time;
  final String? note;
  const _TimeChip(this.prayer, this.time, {this.note});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: Brand.ground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(prayer.displayName,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: Brand.muted)),
                ),
                if (note != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Calculated from $note',
                    child: Icon(Icons.wb_twilight,
                        size: 14, color: Brand.muted, semanticLabel: note),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(time?.to12h() ?? '—',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      );
}

/// "today at 4:53 PM", "yesterday at …", "3 days ago (Oct 14)".
String describeAge(DateTime taken, {DateTime? now}) {
  now ??= DateTime.now();
  final t = Hm(taken.hour, taken.minute).to12h();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(taken.year, taken.month, taken.day))
      .inDays;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return switch (days) {
    <= 0 => 'today at $t',
    1 => 'yesterday at $t',
    _ => '$days days ago (${months[taken.month - 1]} ${taken.day})',
  };
}
