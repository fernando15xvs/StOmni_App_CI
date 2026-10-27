import 'package:flutter/material.dart';

class StOmniMobileTheme {
  static ThemeData create({
    required Color accent,
    required Brightness brightness,
    required bool highContrast,
  }) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xFF090C0E) : const Color(0xFFF5F7F9);
    final surface = dark ? const Color(0xFF14191D) : Colors.white;
    final outline = highContrast
        ? (dark ? const Color(0xFF96ABB6) : const Color(0xFF50616E))
        : (dark ? const Color(0xFF30383E) : const Color(0xFFDCE3E8));
    final foreground = dark ? const Color(0xFFF4F7F8) : const Color(0xFF152027);
    final onAccent = accent.computeLuminance() > 0.179
        ? Colors.black
        : Colors.white;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
          surface: surface,
        ).copyWith(
          primary: accent,
          onPrimary: onAccent,
          onSurface: foreground,
          outline: outline,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardColor: surface,
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w800,
        ),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: outline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(
        color: outline,
        thickness: highContrast ? 1.2 : 0.7,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: outline),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: foreground,
        displayColor: foreground,
      ),
      visualDensity: highContrast
          ? VisualDensity.standard
          : VisualDensity.compact,
    );
  }
}
