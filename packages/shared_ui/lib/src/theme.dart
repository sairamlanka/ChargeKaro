import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Brand palette. Electric green to ocean blue, on a cool neutral base.
abstract final class Brand {
  static const green = Color(0xFF00A86B);
  static const greenDeep = Color(0xFF007A55);
  static const mint = Color(0xFF3DDC97);
  static const ocean = Color(0xFF0284C7);
  static const sky = Color(0xFF38BDF8);
  static const amber = Color(0xFFF59E0B);
  static const ink = Color(0xFF0B1324);
  static const night = Color(0xFF0F1B2D);

  /// The signature gradient for hero areas and primary highlights.
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00A86B), Color(0xFF0091B9), Color(0xFF2563EB)],
    stops: [0, 0.6, 1],
  );

  /// Deep backdrop used behind white text (login, headers).
  static const nightGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF052E2B), Color(0xFF0B2545), Color(0xFF13315C)],
  );

  static const fontFamily = 'PlusJakartaSans';
  static const fontPackage = 'shared_ui';
}

/// One theme for both apps. Status colours come from [StatusTone] so meaning
/// never depends on colour alone (chips also carry text).
abstract final class AppTheme {
  static const brand = Brand.green;

  static ThemeData light() => _build(ColorScheme.fromSeed(
        seedColor: Brand.green,
        primary: Brand.greenDeep,
        secondary: Brand.ocean,
        tertiary: Brand.amber,
        surface: Colors.white,
      ).copyWith(surfaceContainerLowest: Colors.white, surfaceContainerLow: const Color(0xFFF5F8FA)));

  static ThemeData dark() => _build(ColorScheme.fromSeed(
        seedColor: Brand.green,
        brightness: Brightness.dark,
        primary: Brand.mint,
        secondary: Brand.sky,
        tertiary: Brand.amber,
        surface: Brand.night,
      ).copyWith(surfaceContainerLowest: const Color(0xFF13233A), surfaceContainerLow: Brand.ink));

  static const radius = 20.0;
  static const fieldRadius = 14.0;

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: Brand.fontFamily, package: Brand.fontPackage);
    final text = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(fieldRadius));
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.brightness == Brightness.light ? const Color(0xFFF1F5F9) : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(fieldRadius), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: shape,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: shape,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
      chipTheme: base.chipTheme.copyWith(shape: const StadiumBorder(), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        indicatorShape: const StadiumBorder(),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => text.labelMedium?.copyWith(
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
            )),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
        unselectedLabelTextStyle: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(fieldRadius))),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius + 4))),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(fieldRadius)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 24),
    );
  }
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

  /// Solid accent for dots and bars.
  Color accent(ColorScheme scheme) => switch (this) {
        StatusTone.neutral => scheme.outline,
        StatusTone.info => const Color(0xFF1E6FD9),
        StatusTone.success => const Color(0xFF1B8A3A),
        StatusTone.warning => const Color(0xFFD08A1A),
        StatusTone.danger => scheme.error,
      };
}
