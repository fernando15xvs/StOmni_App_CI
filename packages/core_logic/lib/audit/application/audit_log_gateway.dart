import '../domain/audit_log_entry.dart';

abstract interface class AuditLogGateway {
  Future<AuditLogPage> list({
    int limit = 100,
    int? beforeId,
    String? action,
    String? entityType,
  });
}
