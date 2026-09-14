import '../../errors/user_facing_exception.dart';
import '../domain/app_permission.dart';
import 'validate_session_use_case.dart';

abstract interface class OperationAuthorizer {
  String? get currentAuthUserId;

  /// Devuelve el usuario validado; quien ejecuta revalida su identidad antes
  /// de persistir después de cualquier espera asíncrona.
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  });
}

class SessionOperationAuthorizer implements OperationAuthorizer {
  const SessionOperationAuthorizer(this.sessions);
  final ValidateSessionUseCase sessions;

  @override
  String? get currentAuthUserId => sessions.gateway.currentAuthUserId;

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async {
    final result = await sessions.execute(allowOffline: allowOffline);
    if (!result.isAuthorized ||
        result.authUserId == null ||
        !result.permissions.containsAll(permissions)) {
      throw const UserFacingException(
        'No se pudo autorizar esta operación. Verifica tu sesión y permisos.',
      );
    }
    return result.authUserId!;
  }
}
