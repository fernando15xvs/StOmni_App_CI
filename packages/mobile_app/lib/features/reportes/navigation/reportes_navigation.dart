import 'package:flutter/material.dart';

enum ReportesTab { financiero, inventario }

enum ReportesFinancialFilter { todos, ingresos, egresos }

enum ReportesPeriod {
  diario('Diario'),
  semanal('Semanal'),
  mensual('Mensual'),
  anual('Anual'),
  personalizado('Personalizado');

  const ReportesPeriod(this.label);

  final String label;
}

class ReportesInitialContext {
  const ReportesInitialContext({
    this.tab = ReportesTab.financiero,
    this.financialFilter = ReportesFinancialFilter.todos,
    this.period = ReportesPeriod.diario,
    this.specificDate,
    this.customRange,
  });

  final ReportesTab tab;
  final ReportesFinancialFilter financialFilter;
  final ReportesPeriod period;
  final DateTime? specificDate;
  final DateTimeRange? customRange;

  int get tabIndex => tab.index;

  String get financialFilterLabel => switch (financialFilter) {
    ReportesFinancialFilter.todos => 'Todos',
    ReportesFinancialFilter.ingresos => 'Ingresos',
    ReportesFinancialFilter.egresos => 'Egresos',
  };

  String get dateFilterLabel => customRange != null
      ? ReportesPeriod.personalizado.label
      : period.label;
}
