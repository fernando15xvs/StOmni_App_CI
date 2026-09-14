class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.occurredAt,
    required this.action,
    required this.entityType,
    required this.sourceTable,
    required this.sourceOperation,
    required this.metadata,
    this.entityId,
    this.actorUserId,
    this.actorEmployeeId,
    this.actorLabel,
    this.actorRole,
    this.requestId,
  });

  final int id;
  final DateTime occurredAt;
  final String action;
  final String entityType;
  final String? entityId;
  final String sourceTable;
  final String sourceOperation;
  final String? actorUserId;
  final int? actorEmployeeId;
  final String? actorLabel;
  final String? actorRole;
  final String? requestId;
  final Map<String, dynamic> metadata;
}

class AuditLogPage {
  const AuditLogPage({required this.entries, required this.nextBeforeId});

  final List<AuditLogEntry> entries;
  final int? nextBeforeId;
}
