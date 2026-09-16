import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test(
    'arranque usa autorización cacheada solo ante indisponibilidad de red',
    () {
      final useCase = coreFile(
        'lib/auth/application/validate_session_use_case.dart',
      ).readAsStringSync();
      final gateway = coreFile(
        'lib/auth/data/supabase_session_validation_gateway.dart',
      ).readAsStringSync();
      expect(gateway, contains('ErrorMapper.isConnectionError(error)'));
      expect(gateway, contains('AuthSessionCache.loadForUser(authUserId)'));
      expect(useCase, contains('on SessionValidationUnavailable'));
      expect(useCase, contains('cached.isValidFor(userId, _now())'));
      final offlineBranch = useCase.substring(
        useCase.indexOf('on SessionValidationUnavailable'),
      );
      expect(offlineBranch, isNot(contains('invalidateSession(')));
      expect(
        coreFile('lib/splash/services/splash_service.dart').existsSync(),
        isFalse,
      );
      expect(
        File('lib/splash/splash_screen.dart').readAsStringSync(),
        contains('restoreSession()'),
      );
    },
  );

  test('autorización offline tiene TTL y falla cerrado al expirar', () {
    final cache = coreFile(
      'lib/auth/data/auth_session_cache.dart',
    ).readAsStringSync();

    final policy = coreFile(
      'lib/auth/domain/session_authorization.dart',
    ).readAsStringSync();
    expect(policy, contains('offlineAuthorizationTtl = Duration(hours: 24)'));
    expect(
      cache,
      contains('CachedSessionAuthorization.offlineAuthorizationTtl'),
    );
    expect(cache, contains('validatedAt.add(offlineAuthorizationTtl)'));
    expect(
      cache,
      contains(
        'if (!validatedAt.add(offlineAuthorizationTtl).isAfter(now)) return null;',
      ),
    );
    expect(cache, contains('_maxFutureClockSkew'));
    expect(cache, contains('DateTime.tryParse(validatedAtRaw)?.toUtc()'));
  });

  test(
    'solo el gateway de validación online actualiza el snapshot offline',
    () {
      final controller = coreFile(
        'lib/auth/controllers/auth_controller.dart',
      ).readAsStringSync();
      final gateway = coreFile(
        'lib/auth/data/supabase_session_validation_gateway.dart',
      ).readAsStringSync();

      expect(gateway, contains('Future<void> saveAuthorization('));
      expect(gateway, contains('AuthSessionCache.saveValidatedSession'));
      expect(controller, contains('.execute(allowOffline: false)'));
      expect(
        controller,
        isNot(contains('AuthSessionCache.saveValidatedSession')),
      );
    },
  );

  test('cerrar sesión limpia autorización y no usa rol vendedor', () {
    final profile = File(
      'lib/features/empleados/pages/perfil_page.dart',
    ).readAsStringSync();
    final controller = coreFile(
      'lib/auth/controllers/auth_controller.dart',
    ).readAsStringSync();

    expect(profile, contains('authControllerProvider.notifier).signOut()'));
    expect(profile, isNot(contains("state = 'vendedor'")));
    expect(controller, contains('AuthSessionCache.clear()'));
    expect(controller, contains('SignOutScope.local'));
  });

  test('errores de conexión se centralizan en ErrorMapper', () {
    final mapper = coreFile('lib/utils/error_mapper.dart').readAsStringSync();

    expect(mapper, contains('isConnectionError'));
    expect(mapper, contains('connectionMessage'));
    expect(mapper, contains('failed host lookup'));
    expect(mapper, contains('failed to fetch'));
    expect(mapper, contains('503 service unavailable'));
  });
}
