import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/theme/appearance_preview.dart';

void main() {
  testWidgets('Vista previa muestra modo claro y oscuro a la vez', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppearanceThemePreview(
              accent: Color(0xFF1688E8),
              selectedTheme: 'dark',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Modo oscuro'), findsOneWidget);
    expect(find.text('Modo claro'), findsOneWidget);
    expect(find.text('Ingresos'), findsNWidgets(4));
    expect(find.text('S/ 0.00'), findsNWidgets(2));
  });

  testWidgets('Tema automático explica que usa la selección del sistema', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppearanceThemePreview(
            accent: Color(0xFF00A87E),
            selectedTheme: 'system',
          ),
        ),
      ),
    );
    expect(find.textContaining('tema del dispositivo'), findsOneWidget);
  });
}
