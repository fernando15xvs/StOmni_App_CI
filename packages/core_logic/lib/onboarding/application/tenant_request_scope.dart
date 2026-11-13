/// Per-request tenant identity. This is NOT authorization: Postgres must
/// verify that auth.uid() has an active membership and employment in this
/// organization on every request. Do not put this id into global REST headers.
final class TenantRequestScope {
  TenantRequestScope({
    required this.authUserId,
    required this.organizationId,
  }) {
    if (authUserId.trim().isEmpty || !_uuid.hasMatch(organizationId)) {
      throw const FormatException('Identidad o empresa seleccionada inválida.');
    }
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static const String organizationHeader = 'x-stomni-organization-id';

  final String authUserId;
  final String organizationId;

  /// Refuse stale responses if either the Auth identity or the selected
  /// tenant changes while a request is in flight. Callers may pass separate
  /// selections for two concurrently open windows.
  Future<T> execute<T>({
    required String? Function() currentAuthUserId,
    required String? Function() currentSelectedOrganizationId,
    required Future<T> Function(String organizationId) request,
  }) async {
    bool matchesCurrentSession() =>
        currentAuthUserId() == authUserId &&
        currentSelectedOrganizationId() == organizationId;

    if (!matchesCurrentSession()) {
      throw StateError('La sesión o empresa seleccionada cambió.');
    }

    final result = await request(organizationId);

    if (!matchesCurrentSession()) {
      throw StateError('La sesión o empresa seleccionada cambió.');
    }
    return result;
  }
}

/// A tenant context returned by a scoped, server-authorized RPC.
final class VerifiedTenantRequestContext {
  const VerifiedTenantRequestContext({
    required this.organizationId,
    required this.baseRole,
  });

  final String organizationId;
  final String baseRole;

  factory VerifiedTenantRequestContext.fromServer(
    Object? payload, {
    required String requestedOrganizationId,
  }) {
    if (payload is! Map) {
      throw const FormatException('Contexto de organización inválido.');
    }
    final raw = Map<String, dynamic>.from(payload);
    final actualOrganization = raw['organization_id'];
    final role = raw['base_role'];
    if (actualOrganization != requestedOrganizationId ||
        (role != 'admin' && role != 'operador')) {
      throw StateError('El servidor no autorizó la empresa seleccionada.');
    }
    return VerifiedTenantRequestContext(
      organizationId: requestedOrganizationId,
      baseRole: role as String,
    );
  }
}
