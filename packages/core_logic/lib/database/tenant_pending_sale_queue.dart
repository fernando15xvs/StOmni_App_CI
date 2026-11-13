import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../onboarding/application/tenant_request_scope.dart';
import 'pending_sale_queue_store.dart';

/// Durable pending tickets scoped to one authenticated user and one selected
/// organization. The old v1 queue is intentionally left untouched: silently
/// transferring historical sales would risk assigning them to the wrong tenant.
///
/// This is an I3 staging API. Operational sync must not use it until the
/// outgoing RPC transport and all sales writers share the same request scope.
final class TenantPendingSaleQueue {
  TenantPendingSaleQueue({
    required this.scope,
    required this.currentAuthUserId,
    required this.currentSelectedOrganizationId,
    DatabaseFactory? databaseFactoryOverride,
    String? databaseDirectoryOverride,
  }) : _store = PendingSaleQueueStore(
         databaseFactoryOverride: databaseFactoryOverride,
         databasePathOverride: databaseDirectoryOverride == null
             ? null
             : p.join(
                 databaseDirectoryOverride,
                 databaseNameFor(scope.authUserId, scope.organizationId),
               ),
         databaseNameOverride: databaseNameFor(
           scope.authUserId,
           scope.organizationId,
         ),
         webStorageKeyOverride: webKeyFor(
           scope.authUserId,
           scope.organizationId,
         ),
       );

  final TenantRequestScope scope;
  final String? Function() currentAuthUserId;
  final String? Function() currentSelectedOrganizationId;
  final PendingSaleQueueStore _store;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static void _requireIds(String authUserId, String organizationId) {
    if (!_uuid.hasMatch(authUserId) || !_uuid.hasMatch(organizationId)) {
      throw const FormatException(
        'Identificador de usuario o tenant inválido.',
      );
    }
  }

  static String databaseNameFor(String authUserId, String organizationId) {
    _requireIds(authUserId, organizationId);
    return 'stomni_pending_v2_${authUserId.toLowerCase()}_'
        '${organizationId.toLowerCase()}.db';
  }

  static String webKeyFor(String authUserId, String organizationId) {
    _requireIds(authUserId, organizationId);
    return 'stomni_pending_web_v2:${authUserId.toLowerCase()}:'
        '${organizationId.toLowerCase()}';
  }

  void _requireOwnPayload(Map<String, dynamic> payload) {
    if (payload['auth_user_id']?.toString() != scope.authUserId ||
        payload['organization_id']?.toString() != scope.organizationId) {
      throw StateError('Ticket de otra identidad o empresa: acceso denegado.');
    }
  }

  Future<T> _withinSession<T>(Future<T> Function() operation) =>
      scope.execute<T>(
        currentAuthUserId: currentAuthUserId,
        currentSelectedOrganizationId: currentSelectedOrganizationId,
        request: (_) => operation(),
      );

  /// Requires an explicit owner+organization on every newly queued ticket.
  /// Never infer an organization from the globally cached fiscal profile.
  Future<void> saveTicket(Map<String, dynamic> payload) => _withinSession(
    () async {
      _requireOwnPayload(payload);
      final requestId = payload['request_id']?.toString().trim() ?? '';
      final type = payload['tipo_comprobante']?.toString().trim().toLowerCase();
      if (requestId.isEmpty || type != 'ticket_interno') {
        throw ArgumentError('Se requiere un Ticket Interno con request_id.');
      }
      await _store.upsertPayload(Map<String, dynamic>.from(payload));
    },
  );

  Future<List<PendingSaleQueueRecord>> list() => _withinSession(() async {
    final records = await _store.list();
    for (final record in records) {
      _requireOwnPayload(record.payload);
    }
    return List<PendingSaleQueueRecord>.unmodifiable(records);
  });

  Future<int> count() => _withinSession(() async {
    final records = await _store.list();
    for (final record in records) {
      _requireOwnPayload(record.payload);
    }
    return records.length;
  });

  Future<void> deleteByRequestId(String requestId) => _withinSession(() async {
    final id = requestId.trim();
    if (id.isEmpty) throw ArgumentError('request_id inválido.');
    for (final record in await _store.list()) {
      _requireOwnPayload(record.payload);
    }
    await _store.deleteByRequestId(id);
  });

  /// The caller must explicitly acknowledge that only its selected tenant
  /// queue will be removed. Does not touch any legacy or other-tenant records.
  Future<void> clearSelectedTenant() => _withinSession(() => _store.clear());

  /// Closing a retired tenant queue must remain possible after sign-out.
  Future<void> close() => _store.close();
}
