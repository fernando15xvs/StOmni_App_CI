import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/reportes/navigation/reportes_navigation.dart';

void main() {
  test('ReportesInitialContext mapea pestaña, período y filtro financiero', () {
    const entry = ReportesInitialContext(
      tab: ReportesTab.inventario,
      financialFilter: ReportesFinancialFilter.egresos,
      period: ReportesPeriod.mensual,
    );

    expect(entry.tabIndex, 1);
    expect(entry.financialFilterLabel, 'Egresos');
    expect(entry.dateFilterLabel, 'Mensual');
  });

  test('un rango explícito se abre como período personalizado', () {
    final entry = ReportesInitialContext(
      period: ReportesPeriod.semanal,
      customRange: DateTimeRange(
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 30),
      ),
    );

    expect(entry.dateFilterLabel, 'Personalizado');
  });

  test(
    'Balance abre el histórico financiero mediante el contrato de Reportes',
    () {
      final balance = File(
        'lib/features/balance/pages/balance_page.dart',
      ).readAsStringSync();
      final widgets = File(
        'lib/features/balance/widgets/balance_widgets.dart',
      ).readAsStringSync();

      expect(balance, contains('ReportesInitialContext('));
      expect(balance, contains('tab: ReportesTab.financiero'));
      expect(widgets, contains("'Histórico financiero'"));
      expect(widgets, isNot(contains("'Ver reporte'")));
    },
  );
}
