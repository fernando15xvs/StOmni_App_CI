import 'dart:async';

import 'package:core_logic/auth/application/validate_session_use_case.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/auth/domain/session_authorization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 4, 12);
  late _Gateway gateway;
  late ValidateSessionUseCase useCase;

  setUp(() {
    gateway = _Gateway();
    useCase = ValidateSessionUseCase(gateway: gateway, now: () => now);
  });

  CachedSessionAuthorization cached({
    String user = 'user-1',
    String role = 'admin',
    Duration age = const Duration(hours: 1),
  }) => CachedSessionAuthorization(
    authUserId: user,
    role: role,
    validatedAt: now.subtract(age),
    permissions: RolePermissionPolicy.forRole(role),
  );

  test('sin sesión no consulta servidor ni cache', () async {
    gateway.currentAuthUserId = null;
    final result = await useCase.execute();
    expect(result.status, SessionValidationStatus.signedOut);
    expect(result.isAuthorized, isFalse);
    expect(gateway.calls, isEmpty);
  });

  test('validación online normaliza rol y renueva el cache', () async {
    gateway.role = ' OPERADOR ';
    final result = await useCase.execute();
    expect(result.status, SessionValidationStatus.online);
    expect(result.role, 'operador');
    expect(result.isAuthorized, isTrue);
    expect(gateway.saved!.validatedAt, now);
    expect(
      gateway.saved!.permissions,
      RolePermissionPolicy.forRole('operador'),
    );
    expect(gateway.calls, ['remote', 'permissions', 'save']);
  });

  test('cache fallido no bloquea autorización online', () async {
    gateway.failSave = true;
    expect((await useCase.execute()).isAuthorized, isTrue);
  });

  test(
    'identidad elegible sin tenant conserva sesión sólo para onboarding',
    () async {
      gateway.role = null;
      gateway.signupEligible = true;
      gateway.cached = cached();

      final result = await useCase.execute();

      expect(
        result.status,
        SessionValidationStatus.organizationSetupRequired,
      );
      expect(result.requiresOrganizationSetup, isTrue);
      expect(result.isAuthorized, isFalse);
      expect(gateway.currentAuthUserId, 'user-1');
      expect(gateway.saved, isNull);
      expect(gateway.cached, isNull);
      expect(gateway.calls, ['remote', 'clear', 'signup']);
    },
  );

  test('pre-tenant nunca reutiliza cache si falla la elegibilidad', () async {
    gateway.role = null;
    gateway.cached = cached();
    gateway.signupError = const SessionValidationUnavailable();

    final result = await useCase.execute();

    expect(result.status, SessionValidationStatus.unavailable);
    expect(result.isAuthorized, isFalse);
    expect(result.isOffline, isFalse);
    expect(gateway.cached, isNull);
    expect(gateway.calls, ['remote', 'clear', 'signup']);
  });

  test('si no puede borrar cache pre-tenant falla cerrado', () async {
    gateway.role = null;
    gateway.cached = cached();
    gateway.failClear = true;

    final result = await useCase.execute();

    expect(result.status, SessionValidationStatus.failed);
    expect(result.isAuthorized, isFalse);
    expect(gateway.calls, ['remote', 'clear']);
  });

  test('denegación remota no recurre a cache y revoca sesión', () async {
    gateway.role = null;
    gateway.signupEligible = false;
    gateway.cached = cached();

    final result = await useCase.execute();

    expect(result.status, SessionValidationStatus.denied);
    expect(result.isAuthorized, isFalse);
    expect(gateway.cached, isNull);
    expect(gateway.calls, ['remote', 'clear', 'signup', 'invalidate']);
  });

  test('offline vigente permite arrancar sin renovar la autorización', () async {
    gateway.remoteError = const SessionValidationUnavailable();
    gateway.cached = cached();
    final result = await useCase.execute();
    expect(result.isAuthorized, isTrue);
    expect(result.isOffline, isTrue);
    expect(gateway.saved, isNull);
    expect(gateway.calls, ['remote', 'cache']);
  });

  test('sync exige validación online aunque haya cache', () async {
    gateway.remoteError = const SessionValidationUnavailable();
    gateway.cached = cached();
    final result = await useCase.execute(allowOffline: false);
    expect(result.status, SessionValidationStatus.unavailable);
    expect(result.isAuthorized, isFalse);
    expect(gateway.calls, ['remote']);
  });

  test('cache expirado, futuro, ajeno o con rol inválido falla cerrado', () async {
    gateway.remoteError = const SessionValidationUnavailable();
    for (final snapshot in [
      cached(age: const Duration(hours: 24)),
      cached(age: const Duration(minutes: -6)),
      cached(user: 'other'),
      cached(role: 'unknown'),
      null,
    ]) {
      gateway.cached = snapshot;
      final result = await useCase.execute();
      expect(
        result.status,
        SessionValidationStatus.offlineAuthorizationMissing,
      );
      expect(result.isAuthorized, isFalse);
    }
  });

  test('un error desconocido no habilita cache offline', () async {
    gateway.remoteError = StateError('server configuration');
    gateway.cached = cached();
    final result = await useCase.execute();
    expect(result.status, SessionValidationStatus.failed);
    expect(gateway.calls, ['remote']);
  });

  test('respuesta tardía de otro usuario no concede rol ni guarda cache', () async {
    final gate = Completer<void>();
    gateway.remoteGate = gate.future;
    final pending = useCase.execute();
    gateway.currentAuthUserId = 'user-2';
    gate.complete();
    final result = await pending;
    expect(result.status, SessionValidationStatus.sessionChanged);
    expect(result.isAuthorized, isFalse);
    expect(gateway.saved, isNull);
  });

  test('cambio obligatorio de contraseña no concede autorización', () async {
    gateway.requiresPasswordChange = true;
    final result = await useCase.execute();
    expect(result.status, SessionValidationStatus.passwordChangeRequired);
    expect(result.isAuthorized, isFalse);
    expect(gateway.calls, isEmpty);
  });
}

class _Gateway implements SessionValidationGateway {
  @override
  String? currentAuthUserId = 'user-1';

  @override
  bool requiresPasswordChange = false;

  String? role = 'admin';
  bool signupEligible = false;
  Object? signupError;
  Object? remoteError;
  Future<void>? remoteGate;
  bool failSave = false;
  bool failClear = false;
  CachedSessionAuthorization? cached;
  CachedSessionAuthorization? saved;
  final calls = <String>[];

  @override
  Future<String?> readActiveRole(String authUserId) async {
    calls.add('remote');
    if (remoteGate != null) await remoteGate;
    if (remoteError != null) throw remoteError!;
    return role;
  }

  @override
  Future<bool> canStartOrganizationSignup(String authUserId) async {
    calls.add('signup');
    if (signupError != null) throw signupError!;
    return signupEligible;
  }

  @override
  Future<Set<AppPermission>?> readEffectivePermissions(
    String authUserId,
  ) async {
    calls.add('permissions');
    return RolePermissionPolicy.forRole(role);
  }

  @override
  Future<CachedSessionAuthorization?> readCachedAuthorization(
    String authUserId,
  ) async {
    calls.add('cache');
    return cached;
  }

  @override
  Future<void> saveAuthorization(
    CachedSessionAuthorization authorization,
  ) async {
    calls.add('save');
    if (failSave) throw StateError('cache unavailable');
    saved = authorization;
  }

  @override
  Future<void> clearCachedAuthorization(String expectedAuthUserId) async {
    calls.add('clear');
    if (failClear) throw StateError('cache unavailable');
    if (currentAuthUserId == expectedAuthUserId) cached = null;
  }

  @override
  Future<void> invalidateSession(String expectedAuthUserId) async {
    calls.add('invalidate');
    if (currentAuthUserId == expectedAuthUserId) currentAuthUserId = null;
  }
}
