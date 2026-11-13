import '../../errors/user_facing_exception.dart';
import '../../onboarding/application/tenant_request_scope.dart';
import '../domain/app_permission.dart';
import 'operation_authorizer.dart';

/// Server-certified permission snapshot for exactly one selected tenant.
/// Effective permissions never exceed that tenant's canonical base role.
final class TenantVerifiedPermissions {
  TenantVerifiedPermissions({
    required this.organizationId,
    required this.baseRole,
    required this.employeeId,
    required Set<AppPermission> permissions,
  }) : permissions = Set<AppPermission>.unmodifiable(permissions);

  final String organizationId;
  final String baseRole;
  final int employeeId;
  final Set<AppPermission> permissions;

  factory TenantVerifiedPermissions.fromServer(
    VerifiedTenantRequestContext tenant,
    Object? payload,
  ) {
    if (payload is! Map) {
      throw const FormatException('Permisos del servidor inválidos.');
    }
    final raw = Map<String, dynamic>.from(payload);
    final expectedRole = tenant.baseRole == 'admin' ? 'admin' : 'operator';
    final employeeId = raw['employee_id'];
    final codes = raw['permissions'];
    if (raw['supported'] != true ||
        raw['role'] != expectedRole ||
        employeeId is! num ||
        employeeId.toInt() <= 0 ||
        codes is! List ||
        codes.any((code) => code is! String || code.trim().isEmpty)) {
      throw const FormatException('El servidor no acreditó los permisos.');
    }

    // The backend contains permissions outside the narrow Flutter enum.
    // Ignore unknown codes but never allow one of the app's permissions to
    // exceed the base role, even if an employee override is misconfigured.
    final appPermissions = <AppPermission>{};
    for (final code in codes) {
      final permission = AppPermission.fromCode(code as String);
      if (permission != null) appPermissions.add(permission);
    }
    if (!RolePermissionPolicy.forRole(
      tenant.baseRole,
    ).containsAll(appPermissions)) {
      throw StateError('Permisos mayores que el rol base seleccionado.');
    }
    return TenantVerifiedPermissions(
      organizationId: tenant.organizationId,
      baseRole: tenant.baseRole,
      employeeId: employeeId.toInt(),
      permissions: appPermissions,
    );
  }
}

/// Prepared I3 authorization port. It is NOT the default/global provider.
/// Reads only network-verified, tenant-scoped permissions. Offline use stays
/// denied until the v3 per-company authorization cache is wired and tested.
final class TenantOperationAuthorizer implements OperationAuthorizer {
  const TenantOperationAuthorizer({
    required this.scope,
    required String? Function() currentAuthUserId,
    required this.currentSelectedOrganizationId,
    required this.verifyPermissions,
  }) : _readCurrentAuthUserId = currentAuthUserId;

  final TenantRequestScope scope;

  final String? Function() _readCurrentAuthUserId;

  @override
  String? get currentAuthUserId => _readCurrentAuthUserId();

  final String? Function() currentSelectedOrganizationId;
  final Future<TenantVerifiedPermissions> Function(TenantRequestScope)
  verifyPermissions;

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async {
    if (allowOffline) {
      throw const UserFacingException(
        'La autorización offline por empresa no está habilitada.',
      );
    }
    return scope.execute<String>(
      currentAuthUserId: _readCurrentAuthUserId,
      currentSelectedOrganizationId: currentSelectedOrganizationId,
      request: (organizationId) async {
        final verified = await verifyPermissions(scope);
        if (verified.organizationId != organizationId ||
            !RolePermissionPolicy.forRole(
              verified.baseRole,
            ).containsAll(verified.permissions) ||
            !verified.permissions.containsAll(permissions)) {
          throw const UserFacingException(
            'No hay permisos suficientes en la empresa seleccionada.',
          );
        }
        return scope.authUserId;
      },
    );
  }
}
