import '../domain/operational_alert.dart';

abstract interface class OperationalAlertGateway {
  Future<int> refresh();

  Future<List<OperationalAlert>> list({
    OperationalAlertStatus? status,
    int limit = 100,
  });

  Future<void> acknowledge(String alertId);

  Future<String> createTask({
    required String title,
    required String message,
    DateTime? dueAt,
    OperationalAlertSeverity severity = OperationalAlertSeverity.info,
  });

  Future<void> resolve(String alertId);

  Future<OperationalAlertSettings> getSettings();

  Future<OperationalAlertSettings> updateSettings(
    OperationalAlertSettings current,
    OperationalAlertSettings next,
  );
}
