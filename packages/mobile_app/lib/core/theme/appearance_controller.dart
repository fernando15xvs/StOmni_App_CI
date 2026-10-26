import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccentPalette {
  static const names = [
    'Esmeralda',
    'Azul',
    'Índigo',
    'Púrpura',
    'Rosa',
    'Naranja',
    'Ámbar',
    'Rojo',
  ];
  static const colors = [
    Color(0xFF00A87E),
    Color(0xFF1688E8),
    Color(0xFF5859E8),
    Color(0xFF9448DB),
    Color(0xFFE83D80),
    Color(0xFFEE841E),
    Color(0xFFE3A718),
    Color(0xFFDE4548),
  ];

  static Color colorAt(int index) => colors[index.clamp(0, colors.length - 1).toInt()];
}

class AppearanceSettings {
  const AppearanceSettings({
    this.accentIndex = 0,
    this.colorNavigation = true,
    this.highContrast = false,
    this.reduceTransparency = false,
  });

  final int accentIndex;
  final bool colorNavigation;
  final bool highContrast;
  final bool reduceTransparency;

  AppearanceSettings copyWith({
    int? accentIndex,
    bool? colorNavigation,
    bool? highContrast,
    bool? reduceTransparency,
  }) => AppearanceSettings(
    accentIndex: accentIndex ?? this.accentIndex,
    colorNavigation: colorNavigation ?? this.colorNavigation,
    highContrast: highContrast ?? this.highContrast,
    reduceTransparency: reduceTransparency ?? this.reduceTransparency,
  );
}

class AppearanceController extends StateNotifier<AppearanceSettings> {
  AppearanceController() : super(const AppearanceSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = AppearanceSettings(
      accentIndex: (prefs.getInt('mobileAccentIndex') ?? 0).clamp(0, 7).toInt(),
      colorNavigation: prefs.getBool('mobileColorNavigation') ?? true,
      highContrast: prefs.getBool('mobileHighContrast') ?? false,
      reduceTransparency: prefs.getBool('mobileReduceTransparency') ?? false,
    );
  }

  Future<void> apply(AppearanceSettings next) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt('mobileAccentIndex', next.accentIndex),
      prefs.setBool('mobileColorNavigation', next.colorNavigation),
      prefs.setBool('mobileHighContrast', next.highContrast),
      prefs.setBool('mobileReduceTransparency', next.reduceTransparency),
    ]);
    if (mounted) state = next;
  }
}

final appearanceProvider =
    StateNotifierProvider<AppearanceController, AppearanceSettings>(
      (ref) => AppearanceController(),
    );
