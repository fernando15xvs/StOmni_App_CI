import '../../constants/app_roles.dart';
import '../domain/app_permission.dart';
import '../domain/session_authorization.dart';

/// Solo este fallo habilita el uso de una autorización offline vigente.
class SessionValidationUnavailable implements Exception {
  const SessionValidationUnavailable();
}

abstract interface class SessionValidationGateway {
  String? get currentAuthUserId;
  bool get requiresPasswordChange;
  Future<String?> readActiveRole(String authUserId);

  /// Sólo devuelve true si F8.1 confirma que la identidad autenticada está
  /// realmente habilitada para crear su primera organización.
  Future<bool> canStartOrganizationSignup(String authUserId);

  /// `null` significa únicamente que el backend todavía no expone permisos
  /// granulares; en ese caso se conserva la matriz base del rol.
  Future<Set<AppPermission>?> readEffectivePermissions(String authUserId);

  Future<CachedSessionAuthorization?> readCachedAuthorization(
    String authUserId,
  );
  Future<void> saveAuthorization(CachedSessionAuthorization authorization);

  /// Elimina una autorización offline anterior sin cerrar una sesión Auth
  /// todavía elegible para el alta de su primera organización.
  Future<void> clearCachedAuthorization(String expectedAuthUserId);

  Future<void> invalidateSession(String expectedAuthUserId);
}

/// Política única de arranque y revalidación para móvil, escritorio y sync.
class ValidateSessionUseCase {
  ValidateSessionUseCase({required this.gateway, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final SessionValidationGateway gateway;
  final DateTime Function() _now;

  Future<SessionValidationResult> execute({bool allowOffline = true}) async {
    final userId = gateway.currentAuthUserId;
    if (userId == null || userId.trim().isEmpty) {
      return const SessionValidationResult(SessionValidationStatus.signedOut);
    }

    SessionValidationResult result(
      SessionValidationStatus status, {
      String? role,
      Set<AppPermission> permissions = const <AppPermission>{},
    }) => SessionValidationResult(
      status,
      authUserId: userId,
      role: role,
      permissions: permissions,
    );
    bool sessionChanged() => gateway.currentAuthUserId != userId;

    Future<SessionValidationResult> offlineResult() async {
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      if (!allowOffline) {
        return result(SessionValidationStatus.unavailable);
      }

      CachedSessionAuthorization? cached;
      try {
        cached = await gateway.readCachedAuthorization(userId);
      } catch (_) {}
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      if (cached != null && cached.isValidFor(userId, _now())) {
        return result(
          SessionValidationStatus.offline,
          role: AppRoles.normalize(cached.role),
          permissions: cached.permissions,
        );
      }
      return result(SessionValidationStatus.offlineAuthorizationMissing);
    }

    if (gateway.requiresPasswordChange) {
      return result(SessionValidationStatus.passwordChangeRequired);
    }

    String? activeRole;
    try {
      activeRole = await gateway.readActiveRole(userId);
    } on SessionValidationUnavailable {
      return offlineResult();
    } catch (_) {
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      return result(SessionValidationStatus.failed);
    }

    if (sessionChanged()) {
      return result(SessionValidationStatus.sessionChanged);
    }
    final role = AppRoles.normalize(activeRole);

    if (role == null) {
      // Una respuesta online sin tenant invalida cualquier snapshot operativo
      // anterior. A partir de aquí jamás se usa el fallback offline.
      try {
        await gateway.clearCachedAuthorization(userId);
      } catch (_) {
        return result(SessionValidationStatus.failed);
      }
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }

      bool canOnboard;
      try {
        canOnboard = await gateway.canStartOrganizationSignup(userId);
      } on SessionValidationUnavailable {
        // Auth permanece válida para poder reintentar, pero no se concede
        // autorización empresarial ni se reutiliza el snapshot eliminado.
        return result(SessionValidationStatus.unavailable);
      } catch (_) {
        if (sessionChanged()) {
          return result(SessionValidationStatus.sessionChanged);
        }
        return result(SessionValidationStatus.failed);
      }
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      if (canOnboard) {
        return result(SessionValidationStatus.organizationSetupRequired);
      }

      try {
        await gateway.invalidateSession(userId);
      } catch (_) {}
      if (gateway.currentAuthUserId != null && sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      return result(SessionValidationStatus.denied);
    }

    Set<AppPermission>? remotePermissions;
    try {
      remotePermissions = await gateway.readEffectivePermissions(userId);
    } on SessionValidationUnavailable {
      return offlineResult();
    } catch (_) {
      if (sessionChanged()) {
        return result(SessionValidationStatus.sessionChanged);
      }
      return result(SessionValidationStatus.failed);
    }
    if (sessionChanged()) {
      return result(SessionValidationStatus.sessionChanged);
    }

    final permissions = remotePermissions ?? RolePermissionPolicy.forRole(role);
    final base = RolePermissionPolicy.forRole(role);
    if (!base.containsAll(permissions)) {
      return result(SessionValidationStatus.failed);
    }

    final authorization = CachedSessionAuthorization(
      authUserId: userId,
      role: role,
      validatedAt: _now().toUtc(),
      permissions: permissions,
    );
    try {
      await gateway.saveAuthorization(authorization);
    } catch (_) {
      // Fallar al guardar caché no invalida una autorización online válida.
    }
    if (sessionChanged()) {
      return result(SessionValidationStatus.sessionChanged);
    }
    return result(
      SessionValidationStatus.online,
      role: role,
      permissions: permissions,
    );
  }
}
