import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:salat_reader/salat_reader.dart';

import '../theme.dart';

/// Number shown on a prayer's pin and its tile, so the two can be matched.
int? prayerNumber(Prayer p) => switch (p) {
      Prayer.fajr => 1,
      Prayer.dhuhr => 2,
      Prayer.asr => 3,
      Prayer.maghrib => 4,
      Prayer.isha => 5,
      Prayer.jumuah => 6,
      Prayer.sunrise => null,
    };

/// The photo with a numbered pin on each clock or time the app read. Pins
/// are brass when confident, amber when the time needs checking, red when
/// the clock couldn't be read; the board's own clock gets a clock pin.
class BoardOverlay extends StatelessWidget {
  final Uint8List bytes;
  final BoardReading reading;

  const BoardOverlay({super.key, required this.bytes, required this.reading});

  @override
  Widget build(BuildContext context) {
    final aspect = reading.imageWidth / reading.imageHeight;
    return Container(
      color: Colors.black,
      constraints: const BoxConstraints(maxHeight: 480),
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: InteractiveViewer(
            maxScale: 6,
            child: LayoutBuilder(builder: (context, box) {
              final sx = box.maxWidth / reading.imageWidth;
              final sy = box.maxHeight / reading.imageHeight;
              Offset anchor(Region r) {
                // Upper-left of the clock's rim (or the text's corner),
                // so the pin doesn't hide the hands.
                if (r.oval) {
                  final rad = r.width / 2 * 0.72;
                  return Offset((r.centerX - rad) * sx, (r.centerY - rad) * sy);
                }
                return Offset(r.left * sx, r.top * sy);
              }

              final pins = <Widget>[];
              void pin(Region r, Widget child, Color fill, String label,
                  {Color? border}) {
                final at = anchor(r);
                pins.add(Positioned(
                  left:
                      (at.dx - 15).clamp(2.0, math.max(2.0, box.maxWidth - 32)),
                  top: (at.dy - 15)
                      .clamp(2.0, math.max(2.0, box.maxHeight - 32)),
                  child: Semantics(
                    label: label,
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: fill,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: border ?? Brand.onBrass, width: 2),
                      ),
                      child: child,
                    ),
                  ),
                ));
              }

              Text number(String s) => Text(s,
                  style: const TextStyle(
                      color: Brand.onBrass,
                      fontSize: 14,
                      fontWeight: FontWeight.w800));

              for (final t in reading.times) {
                final r = t.region;
                if (r == null) continue;
                final p = t.prayer;
                final n = p == null ? null : prayerNumber(p);
                final unsure = t.confidence < 0.8;
                pin(
                  r,
                  number(n?.toString() ?? (p == Prayer.sunrise ? 'S' : '?')),
                  p == null
                      ? Brand.muted
                      : (unsure ? Brand.check : Brand.brass),
                  '${p?.displayName ?? 'Unassigned'} ${t.time.to12h()}'
                  '${unsure ? ', please check' : ''}',
                );
              }
              for (final m in reading.missing) {
                final n = m.prayer == null ? null : prayerNumber(m.prayer!);
                pin(m.region, number(n?.toString() ?? '?'), Brand.error,
                    '${m.prayer?.displayName ?? 'A clock'} could not be read');
              }
              final clock = reading.displayClock;
              if (clock?.region != null) {
                pin(
                    clock!.region!,
                    const Icon(Icons.schedule, size: 17, color: Brand.text),
                    Brand.ground,
                    'Board clock ${clock.time.to12h()}',
                    border: Brand.brass);
              }

              return Stack(
                fit: StackFit.expand,
                children: [Image.memory(bytes, fit: BoxFit.fill), ...pins],
              );
            }),
          ),
        ),
      ),
    );
  }
}
