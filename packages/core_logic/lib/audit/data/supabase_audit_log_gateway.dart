import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/audit_log_gateway.dart';
import '../domain/audit_log_entry.dart';

class SupabaseAuditLogGateway implements AuditLogGateway {
  const SupabaseAuditLogGateway(this.client);

  final SupabaseClient client;

  @override
  Future<AuditLogPage> list({
    int limit = 100,
    int? beforeId,
    String? action,
    String? entityType,
  }) async {
    final normalizedAction = action?.trim();
    final normalizedEntity = entityType?.trim();
    final raw = await client.rpc(
      'list_audit_logs_v1',
      params: <String, dynamic>{
        'p_limit': limit,
        'p_before_id': beforeId,
        'p_action': normalizedAction?.isEmpty == true ? null : normalizedAction,
        'p_entity_type': normalizedEntity?.isEmpty == true
            ? null
            : normalizedEntity,
      },
    );
    if (raw is! List) {
      throw const FormatException('El historial de auditoría es inválido.');
    }
    final entries = raw.map(_decode).toList(growable: false);
    return AuditLogPage(
      entries: List<AuditLogEntry>.unmodifiable(entries),
      nextBeforeId: entries.length < limit || entries.isEmpty
          ? null
          : entries.last.id,
    );
  }

  AuditLogEntry _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Evento de auditoría inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final id = _int(map['id']);
    final occurredAt = DateTime.tryParse(map['occurred_at']?.toString() ?? '');
    final action = map['action']?.toString().trim() ?? '';
    final entityType = map['entity_type']?.toString().trim() ?? '';
    final sourceTable = map['source_table']?.toString().trim() ?? '';
    final sourceOperation = map['source_operation']?.toString().trim() ?? '';
    final metadataRaw = map['metadata'];
    if (id == null ||
        id <= 0 ||
        occurredAt == null ||
        action.isEmpty ||
        entityType.isEmpty ||
        sourceTable.isEmpty ||
        sourceOperation.isEmpty ||
        metadataRaw is! Map) {
      throw const FormatException('Contrato de auditoría incompleto.');
    }
    return AuditLogEntry(
      id: id,
      occurredAt: occurredAt,
      action: action,
      entityType: entityType,
      entityId: _nullableText(map['entity_id']),
      sourceTable: sourceTable,
      sourceOperation: sourceOperation,
      actorUserId: _nullableText(map['actor_user_id']),
      actorEmployeeId: _int(map['actor_employee_id']),
      actorLabel: _nullableText(map['actor_label']),
      actorRole: _nullableText(map['actor_role']),
      requestId: _nullableText(map['request_id']),
      metadata: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(metadataRaw),
      ),
    );
  }

  int? _int(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  String? _nullableText(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }
}
