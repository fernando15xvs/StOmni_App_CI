import '../../constants/app_roles.dart';
import 'app_permission.dart';

enum SessionValidationStatus {
  signedOut,
  organizationSetupRequired,
  online,
  offline,
  denied,
  unavailable,
  offlineAuthorizationMissing,
  passwordChangeRequired,
  sessionChanged,
  failed,
}

/// Autorización ya verificada, nunca credenciales ni tokens de sesión.
class CachedSessionAuthorization {
  const CachedSessionAuthorization({
    required this.authUserId,
    required this.role,
    required this.validatedAt,
    this.permissions = const <AppPermission>{},
  });

  static const offlineAuthorizationTtl = Duration(hours: 24);
  static const maxFutureClockSkew = Duration(minutes: 5);

  final String authUserId;
  final String role;
  final DateTime validatedAt;
  final Set<AppPermission> permissions;

  bool isValidFor(String userId, DateTime now) {
    final timestamp = validatedAt.toUtc();
    final instant = now.toUtc();
    final base = RolePermissionPolicy.forRole(role);
    return authUserId == userId &&
        AppRoles.normalize(role) != null &&
        base.containsAll(permissions) &&
        !timestamp.isAfter(instant.add(maxFutureClockSkew)) &&
        timestamp.add(offlineAuthorizationTtl).isAfter(instant);
  }
}

class SessionValidationResult {
  const SessionValidationResult(
    this.status, {
    this.authUserId,
    this.role,
    this.permissions = const <AppPermission>{},
  });

  final SessionValidationStatus status;
  final String? authUserId;
  final String? role;
  final Set<AppPermission> permissions;

  bool get isAuthorized =>
      (status == SessionValidationStatus.online ||
          status == SessionValidationStatus.offline) &&
      AppRoles.normalize(role) != null;

  /// Sesión Auth válida, pero todavía sin tenant. No autoriza ninguna operación
  /// empresarial ni puede usar autorización offline hasta completar F8.1.
  bool get requiresOrganizationSetup =>
      status == SessionValidationStatus.organizationSetupRequired;

  bool get isOffline => status == SessionValidationStatus.offline;
}
