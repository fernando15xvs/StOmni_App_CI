enum OperationalAlertCategory {
  stockLow('stock_low'),
  expiry('expiry'),
  debtOverdue('debt_overdue'),
  purchasePending('purchase_pending'),
  cashSessionOpen('cash_session_open'),
  task('task');

  const OperationalAlertCategory(this.databaseValue);
  final String databaseValue;

  static OperationalAlertCategory parse(String raw) =>
      OperationalAlertCategory.values.firstWhere(
        (value) => value.databaseValue == raw.trim().toLowerCase(),
        orElse: () =>
            throw FormatException('Categoría de alerta desconocida: $raw'),
      );
}

enum OperationalAlertSeverity {
  info('info'),
  warning('warning'),
  critical('critical');

  const OperationalAlertSeverity(this.databaseValue);
  final String databaseValue;

  static OperationalAlertSeverity parse(String raw) =>
      OperationalAlertSeverity.values.firstWhere(
        (value) => value.databaseValue == raw.trim().toLowerCase(),
        orElse: () =>
            throw FormatException('Severidad de alerta desconocida: $raw'),
      );
}

enum OperationalAlertStatus {
  open('open'),
  acknowledged('acknowledged'),
  resolved('resolved');

  const OperationalAlertStatus(this.databaseValue);
  final String databaseValue;

  static OperationalAlertStatus parse(String raw) =>
      OperationalAlertStatus.values.firstWhere(
        (value) => value.databaseValue == raw.trim().toLowerCase(),
        orElse: () =>
            throw FormatException('Estado de alerta desconocido: $raw'),
      );
}

class OperationalAlert {
  OperationalAlert({
    required this.id,
    required this.category,
    required this.severity,
    required this.status,
    required this.title,
    required this.message,
    required this.firstDetectedAt,
    required this.lastDetectedAt,
    required Map<String, dynamic> metadata,
    this.entityType,
    this.entityId,
    this.dueAt,
    this.acknowledgedAt,
    this.resolvedAt,
  }) : metadata = Map<String, dynamic>.unmodifiable(metadata);

  final String id;
  final OperationalAlertCategory category;
  final OperationalAlertSeverity severity;
  final OperationalAlertStatus status;
  final String? entityType;
  final String? entityId;
  final String title;
  final String message;
  final DateTime? dueAt;
  final DateTime firstDetectedAt;
  final DateTime lastDetectedAt;
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final Map<String, dynamic> metadata;
}

class OperationalAlertSettings {
  const OperationalAlertSettings({
    required this.lowStockEnabled,
    required this.expiryEnabled,
    required this.expiryWarningDays,
    required this.debtOverdueEnabled,
    required this.debtOverdueDays,
    required this.purchasePendingEnabled,
    required this.purchasePendingDays,
    required this.cashSessionEnabled,
    required this.cashSessionMaxHours,
    required this.revision,
  });

  final bool lowStockEnabled;
  final bool expiryEnabled;
  final int expiryWarningDays;
  final bool debtOverdueEnabled;
  final int debtOverdueDays;
  final bool purchasePendingEnabled;
  final int purchasePendingDays;
  final bool cashSessionEnabled;
  final int cashSessionMaxHours;
  final int revision;
}
