import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/theme/appearance_controller.dart';
import 'package:mobile_app/core/theme/stomni_mobile_theme.dart';

void main() {
  test('Apariencia ofrece ocho colores distinguibles', () {
    expect(AccentPalette.names, hasLength(8));
    expect(AccentPalette.colors.toSet(), hasLength(8));
    expect(AccentPalette.colorAt(-1), AccentPalette.colors.first);
    expect(AccentPalette.colorAt(100), AccentPalette.colors.last);
  });

  testWidgets('Ambos temas respetan sus superficies sin blanco forzado',
      (tester) async {
    final dark = StOmniMobileTheme.create(
      accent: AccentPalette.colors[2],
      brightness: Brightness.dark,
      highContrast: false,
    );
    final light = StOmniMobileTheme.create(
      accent: AccentPalette.colors[2],
      brightness: Brightness.light,
      highContrast: false,
    );
    expect(dark.scaffoldBackgroundColor, isNot(Colors.white));
    expect(dark.cardColor, isNot(Colors.white));
    expect(dark.colorScheme.primary, AccentPalette.colors[2]);
    expect(light.brightness, Brightness.light);
    expect(light.colorScheme.primary, AccentPalette.colors[2]);
  });

  test('Cambiar acento conserva controles independientes', () {
    const settings = AppearanceSettings(
      colorNavigation: false,
      reduceTransparency: true,
    );
    final changed = settings.copyWith(accentIndex: 7);
    expect(changed.accentIndex, 7);
    expect(changed.colorNavigation, isFalse);
    expect(changed.reduceTransparency, isTrue);
  });
}
