import 'package:flutter/material.dart';

/// One theme for both apps. Colours are seeded from a single brand green;
/// status colours come from [StatusTone] so meaning never depends on colour
/// alone (chips also carry text).
abstract final class AppTheme {
  static const brand = Color(0xFF0F7A4F);

  static ThemeData light() => _build(ColorScheme.fromSeed(seedColor: brand));
  static ThemeData dark() => _build(ColorScheme.fromSeed(seedColor: brand, brightness: Brightness.dark));

  static ThemeData _build(ColorScheme scheme) => ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      );
}

enum StatusTone { neutral, info, success, warning, danger }

extension StatusToneColors on StatusTone {
  (Color background, Color foreground) colors(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    Color tint(Color c) => Color.alphaBlend(c.withValues(alpha: dark ? 0.28 : 0.14), scheme.surface);
    Color text(Color c) => dark ? Color.lerp(c, Colors.white, 0.55)! : Color.lerp(c, Colors.black, 0.35)!;
    return switch (this) {
      StatusTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      StatusTone.info => (tint(const Color(0xFF1E6FD9)), text(const Color(0xFF1E6FD9))),
      StatusTone.success => (tint(const Color(0xFF1B8A3A)), text(const Color(0xFF1B8A3A))),
      StatusTone.warning => (tint(const Color(0xFFB7791F)), text(const Color(0xFFB7791F))),
      StatusTone.danger => (tint(scheme.error), text(scheme.error)),
    };
  }
}
