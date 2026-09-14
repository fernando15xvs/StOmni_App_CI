enum BusinessAssistantIntent {
  replenishment('replenishment'),
  nonMovingProducts('non_moving_products'),
  overdueReceivables('overdue_receivables'),
  marginDiagnostics('margin_diagnostics');

  const BusinessAssistantIntent(this.databaseValue);
  final String databaseValue;

  static BusinessAssistantIntent parse(String raw) =>
      BusinessAssistantIntent.values.firstWhere(
        (value) => value.databaseValue == raw.trim().toLowerCase(),
        orElse: () => throw FormatException('Intención de asistente desconocida: $raw'),
      );
}

class BusinessAssistantSettings {
  const BusinessAssistantSettings({
    required this.enabled,
    required this.maxResultItems,
    required this.defaultPeriodDays,
    required this.revision,
  });

  final bool enabled;
  final int maxResultItems;
  final int defaultPeriodDays;
  final int revision;
}

class BusinessAssistantContext {
  BusinessAssistantContext({
    required this.intent,
    required this.periodDays,
    required Iterable<Map<String, dynamic>> items,
    required this.generatedAt,
    this.branchId,
    this.branchName,
    this.note,
  }) : items = List<Map<String, dynamic>>.unmodifiable(
          items.map((item) => Map<String, dynamic>.unmodifiable(item)),
        );

  final BusinessAssistantIntent intent;
  final int periodDays;
  final String? branchId;
  final String? branchName;
  final List<Map<String, dynamic>> items;
  final String? note;
  final DateTime generatedAt;
}
