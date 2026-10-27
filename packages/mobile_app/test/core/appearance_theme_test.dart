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

  testWidgets('Ambos temas respetan sus superficies sin blanco forzado', (
    tester,
  ) async {
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

  test('Ocho acentos ofrecen contraste de al menos 4.5 en acciones', () {
    for (final accent in AccentPalette.colors) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final scheme = StOmniMobileTheme.create(
          accent: accent,
          brightness: brightness,
          highContrast: false,
        ).colorScheme;
        final primaryLuminance = scheme.primary.computeLuminance();
        final textLuminance = scheme.onPrimary.computeLuminance();
        final lighter = primaryLuminance > textLuminance
            ? primaryLuminance
            : textLuminance;
        final darker = primaryLuminance < textLuminance
            ? primaryLuminance
            : textLuminance;
        expect(
          (lighter + 0.05) / (darker + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: 'Acento $accent en $brightness',
        );
      }
    }
  });

  test('Contraste mejorado distingue superficies en ambos temas', () {
    final normal = StOmniMobileTheme.create(
      accent: AccentPalette.colors[0],
      brightness: Brightness.dark,
      highContrast: false,
    );
    final strong = StOmniMobileTheme.create(
      accent: AccentPalette.colors[0],
      brightness: Brightness.dark,
      highContrast: true,
    );
    expect(strong.colorScheme.outline, isNot(normal.colorScheme.outline));
    expect(
      strong.dividerTheme.thickness,
      greaterThan(normal.dividerTheme.thickness!),
    );
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
