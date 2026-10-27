import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/widgets/global_date_filter.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('Subtítulo de fecha respeta tema $brightness', (tester) async {
      final theme = ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1688E8),
          brightness: brightness,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(
              title: Column(
                children: [
                  const Text('Reportes'),
                  GlobalDateFilterWidget.buildTitleWidget(
                    filterState: GlobalDateFilterState(filtroTipo: 'Semanal'),
                    onSelectFechaEspecifica: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final subtitle = tester.widget<Text>(find.text('Semanal'));
      expect(subtitle.style?.color, theme.colorScheme.onSurfaceVariant);
    });
  }
}
