enum MetricSource {
  income('income'),
  expenses('expenses'),
  netCashFlow('net_cash_flow'),
  discounts('discounts'),
  salesCount('sales_count'),
  inventoryEntries('inventory_entries'),
  inventoryExits('inventory_exits'),
  salesRevenue('sales_revenue'),
  grossMargin('gross_margin'),
  inventoryTurnover('inventory_turnover'),
  deadInventoryItems('dead_inventory_items'),
  accountsReceivable('accounts_receivable'),
  cashPerformancePercent('cash_performance_percent');

  const MetricSource(this.databaseValue);
  final String databaseValue;

  static MetricSource parse(String raw) => MetricSource.values.firstWhere(
    (value) => value.databaseValue == raw.trim().toLowerCase(),
    orElse: () => throw FormatException('Métrica desconocida: $raw'),
  );
}

enum MetricFormat {
  currency('currency'),
  number('number');

  const MetricFormat(this.databaseValue);
  final String databaseValue;

  static MetricFormat parse(String raw) => MetricFormat.values.firstWhere(
    (value) => value.databaseValue == raw.trim().toLowerCase(),
    orElse: () => throw FormatException('Formato de métrica desconocido: $raw'),
  );
}

class ConfigurableMetricDefinition {
  const ConfigurableMetricDefinition({
    required this.source,
    required this.label,
    required this.position,
    required this.enabled,
    required this.format,
  });

  final MetricSource source;
  final String label;
  final int position;
  final bool enabled;
  final MetricFormat format;
}

class MetricValue {
  const MetricValue({
    required this.definition,
    this.value,
    this.available = true,
    this.note,
  });

  final ConfigurableMetricDefinition definition;
  final double? value;
  final bool available;
  final String? note;
}

class ConfigurableDashboardSnapshot {
  ConfigurableDashboardSnapshot({
    required this.start,
    required this.end,
    required Iterable<MetricValue> metrics,
    this.branchId,
    this.branchName,
    this.scopeNote,
  }) : metrics = List<MetricValue>.unmodifiable(metrics);

  final DateTime start;
  final DateTime end;
  final String? branchId;
  final String? branchName;
  final String? scopeNote;
  final List<MetricValue> metrics;
}
