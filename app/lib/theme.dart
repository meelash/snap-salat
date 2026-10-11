import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The "Brass Geometric" look: masjid-board green with brass accents.
class Brand {
  static const ground = Color(0xFF0E2A21);
  static const surface = Color(0xFF143629);
  static const outline = Color(0xFF3C5E50);
  static const brass = Color(0xFFD4AF5F);
  static const onBrass = Color(0xFF1A1A12);
  static const text = Color(0xFFF1ECDF);
  static const muted = Color(0xFFC3CFC7);

  /// "Please check": amber, and its tinted tile background.
  static const check = Color(0xFFF2B04A);
  static const checkSurface = Color(0xFF2E2A17);
  static const ok = Color(0xFF8FD3AE);
  static const error = Color(0xFFFF8A80);

  static const arabicFont = 'ReemKufi';

  static ThemeData theme() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: brass,
      onPrimary: onBrass,
      secondary: brass,
      onSecondary: onBrass,
      secondaryContainer: surface,
      onSecondaryContainer: text,
      tertiary: check,
      onTertiary: onBrass,
      tertiaryContainer: checkSurface,
      onTertiaryContainer: check,
      error: error,
      onError: onBrass,
      surface: ground,
      onSurface: text,
      onSurfaceVariant: muted,
      surfaceContainerHighest: surface,
      surfaceContainerHigh: surface,
      surfaceContainer: surface,
      outline: outline,
      outlineVariant: Color(0xFF2B5143),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Figtree',
      scaffoldBackgroundColor: ground,
    );
    const pill = StadiumBorder();
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: ground,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
            fontFamily: 'Figtree',
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: text),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brass,
          foregroundColor: onBrass,
          minimumSize: const Size.fromHeight(56),
          shape: pill,
          textStyle: const TextStyle(
              fontFamily: 'Figtree', fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: outline),
          shape: pill,
          textStyle: const TextStyle(
              fontFamily: 'Figtree', fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFE2C27A),
          textStyle: const TextStyle(
              fontFamily: 'Figtree', fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: outline)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: outline)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: brass, width: 2)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: brass,
        unselectedLabelColor: muted,
        indicatorColor: brass,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(fontFamily: 'Figtree', color: text),
      ),
    );
  }
}

/// Girih-style eight-pointed star tiling, fading out downwards.
class GirihPattern extends StatelessWidget {
  final double opacity;
  const GirihPattern({super.key, this.opacity = 0.22});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: ClipRect(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.transparent],
            ).createShader(r),
            child: CustomPaint(
                painter: _GirihPainter(Brand.brass.withValues(alpha: opacity)),
                size: Size.infinite),
          ),
        ),
      );
}

class _GirihPainter extends CustomPainter {
  final Color colour;
  _GirihPainter(this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 56.0;
    final p = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final c = Offset(x + cell / 2, y + cell / 2);
        final square = Rect.fromCenter(center: c, width: 28, height: 28);
        canvas.drawRect(square, p);
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(
            Rect.fromCenter(center: Offset.zero, width: 28, height: 28), p);
        canvas.restore();
        canvas.drawCircle(c, 6, p);
        canvas.drawLine(Offset(x, y), Offset(x + 14, y + 14), p);
        canvas.drawLine(Offset(x + cell, y), Offset(x + cell - 14, y + 14), p);
        canvas.drawLine(Offset(x, y + cell), Offset(x + 14, y + cell - 14), p);
        canvas.drawLine(Offset(x + cell, y + cell),
            Offset(x + cell - 14, y + cell - 14), p);
      }
    }
  }

  @override
  bool shouldRepaint(_GirihPainter old) => old.colour != colour;
}

/// Arabic names for the prayers, shown beside the English ones.
const arabicPrayerNames = {
  'fajr': 'فجر',
  'sunrise': 'شروق',
  'dhuhr': 'ظهر',
  'asr': 'عصر',
  'maghrib': 'مغرب',
  'isha': 'عشاء',
  'jumuah': 'جمعة',
};
