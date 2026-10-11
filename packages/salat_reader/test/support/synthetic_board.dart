import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// A synthetic analog prayer board with known times, for robustness tests.
class SyntheticBoard {
  final img.Image image;

  /// Minutes past 12:00 shown by each prayer clock, in RTL row order
  /// (Fajr, Dhuhr, Asr, Maghrib, Isha, Jumu'ah).
  final List<int> minutes12;

  /// Minutes past 12:00 on the big current-time clock.
  final int currentMinutes12;

  SyntheticBoard(this.image, this.minutes12, this.currentMinutes12);
}

/// Plausible iqamah times (minutes after midnight) for the six clocks.
List<int> randomPrayerTimes(math.Random rng) {
  int pick(int from, int to) => from + rng.nextInt(to - from);
  final asr = pick(15 * 60 + 15, 18 * 60);
  final maghrib = pick(math.max(asr + 30, 17 * 60), 20 * 60 + 30);
  final isha = pick(maghrib + 45, 22 * 60 + 30);
  return [
    pick(4 * 60 + 30, 7 * 60), // fajr
    pick(12 * 60 + 30, 14 * 60), // dhuhr
    asr,
    maghrib,
    isha,
    pick(12 * 60 + 30, 14 * 60), // jumuah
  ];
}

/// Renders a board like the common Hartco style: a big clock on top and
/// a 2×3 grid of prayer clocks, with random hand styles, shadows, camera
/// roll, mild perspective, glare, blur and noise.
SyntheticBoard renderBoard(math.Random rng, List<int> times24, int current24) {
  const w = 1200, h = 1700;
  final board = img.Image(width: w, height: h);
  img.fill(board, color: img.ColorRgb8(225, 225, 222)); // wall
  img.fillRect(board,
      x1: 180, y1: 60, x2: 1020, y2: 1640, color: img.ColorRgb8(28, 58, 44));

  final hollow = rng.nextBool();
  final shadow = rng.nextBool();
  void clock(double cx, double cy, double r, int minutes12) {
    img.fillCircle(board,
        x: cx.round(), y: cy.round(), radius: r.round(),
        color: img.ColorRgb8(196, 164, 92));
    img.fillCircle(board,
        x: cx.round(), y: cy.round(), radius: (r * 0.9).round(),
        color: img.ColorRgb8(236, 232, 220));
    for (var t = 0; t < 60; t++) {
      final a = t * math.pi / 30;
      final r0 = r * (t % 5 == 0 ? 0.78 : 0.83);
      img.drawLine(board,
          x1: (cx + r0 * math.sin(a)).round(), y1: (cy - r0 * math.cos(a)).round(),
          x2: (cx + r * 0.87 * math.sin(a)).round(), y2: (cy - r * 0.87 * math.cos(a)).round(),
          color: img.ColorRgb8(40, 40, 40), thickness: t % 5 == 0 ? 3 : 1);
    }
    final font = r > 150 ? img.arial48 : img.arial24;
    for (var n = 1; n <= 12; n++) {
      final a = n * math.pi / 6;
      final s = '$n';
      final tx = cx + r * 0.62 * math.sin(a), ty = cy - r * 0.62 * math.cos(a);
      img.drawString(board, s,
          font: font,
          x: (tx - font.size * 0.28 * s.length).round(),
          y: (ty - font.size * 0.55).round(),
          color: img.ColorRgb8(30, 30, 30));
    }
    void hand(double deg, double len, double width, img.Color c, double ox, double oy) {
      final a = deg * math.pi / 180;
      final sx = math.sin(a), sy = -math.cos(a);
      final tipX = cx + ox + len * r * sx, tipY = cy + oy + len * r * sy;
      final tailX = cx + ox - 0.15 * r * sx, tailY = cy + oy - 0.15 * r * sy;
      final px = -sy * width * r / 2, py = sx * width * r / 2;
      if (hollow) {
        for (final side in [-1, 1]) {
          img.drawLine(board,
              x1: (tailX + side * px).round(), y1: (tailY + side * py).round(),
              x2: tipX.round(), y2: tipY.round(), color: c, thickness: 2);
        }
        img.drawLine(board,
            x1: (tailX - px).round(), y1: (tailY - py).round(),
            x2: (tailX + px).round(), y2: (tailY + py).round(), color: c, thickness: 2);
      } else {
        img.fillPolygon(board, vertices: [
          img.Point(tailX + px, tailY + py),
          img.Point(tipX + px * 0.3, tipY + py * 0.3),
          img.Point(tipX - px * 0.3, tipY - py * 0.3),
          img.Point(tailX - px, tailY - py),
        ], color: c);
      }
    }

    final hourDeg = minutes12 / 2.0, minuteDeg = (minutes12 % 60) * 6.0;
    final hourLen = 0.45 + rng.nextDouble() * 0.1;
    final minuteLen = 0.7 + rng.nextDouble() * 0.1;
    // Cheap movements: the hour hand is often a few degrees off.
    final slop = (rng.nextDouble() - 0.5) * 8;
    if (shadow) {
      final shadowColour = img.ColorRgb8(150, 148, 140);
      hand(hourDeg + slop, hourLen, 0.08, shadowColour, r * 0.03, r * 0.04);
      hand(minuteDeg, minuteLen, 0.06, shadowColour, r * 0.03, r * 0.04);
    }
    final black = img.ColorRgb8(25, 25, 25);
    hand(hourDeg + slop, hourLen, 0.08, black, 0, 0);
    hand(minuteDeg, minuteLen, 0.06, black, 0, 0);
    img.fillCircle(board,
        x: cx.round(), y: cy.round(), radius: (r * 0.07).round(), color: black);
  }

  clock(600, 330, 230, current24 % 720);
  final m12 = [for (final t in times24) t % 720];
  // RTL rows: (right, left) per row.
  final positions = [
    (790.0, 800.0), (410.0, 800.0),
    (790.0, 1110.0), (410.0, 1110.0),
    (790.0, 1420.0), (410.0, 1420.0),
  ];
  for (var i = 0; i < 6; i++) {
    clock(positions[i].$1, positions[i].$2, 125, m12[i]);
  }

  // Glare: a soft bright blob somewhere on the board.
  if (rng.nextBool()) {
    final gx = 250 + rng.nextInt(700), gy = 600 + rng.nextInt(900);
    final gr = 60 + rng.nextInt(90);
    for (var y = gy - gr; y < gy + gr; y++) {
      for (var x = gx - gr; x < gx + gr; x++) {
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        final d = math.sqrt(math.pow(x - gx, 2) + math.pow(y - gy, 2)) / gr;
        if (d >= 1) continue;
        final k = 0.75 * (1 - d * d);
        final p = board.getPixel(x, y);
        board.setPixelRgb(x, y, p.r + (255 - p.r) * k, p.g + (255 - p.g) * k,
            p.b + (255 - p.b) * k);
      }
    }
  }

  // Camera: roll, mild perspective (anisotropic scale), blur, noise.
  var photo = img.copyRotate(board,
      angle: (rng.nextDouble() - 0.5) * 8, interpolation: img.Interpolation.linear);
  final squash = 0.88 + rng.nextDouble() * 0.12;
  photo = img.copyResize(photo,
      width: (photo.width * squash).round(), height: photo.height,
      interpolation: img.Interpolation.average);
  photo = img.gaussianBlur(photo, radius: 1);
  photo = img.noise(photo, 6, random: rng);
  return SyntheticBoard(photo, m12, current24 % 720);
}
