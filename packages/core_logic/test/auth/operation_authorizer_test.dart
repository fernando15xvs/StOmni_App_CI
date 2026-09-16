import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matriz de permisos conserva roles y deniega desconocidos', () {
    expect(
      RolePermissionPolicy.allows('admin', AppPermission.productsCreate),
      isTrue,
    );
    expect(
      RolePermissionPolicy.allows('admin', AppPermission.purchasesManage),
      isTrue,
    );
    expect(
      RolePermissionPolicy.allows('operador', AppPermission.salesCreate),
      isTrue,
    );
    expect(
      RolePermissionPolicy.allows(
        'operador',
        AppPermission.productsChangePrice,
      ),
      isFalse,
    );
    expect(
      RolePermissionPolicy.allows('operador', AppPermission.purchasesManage),
      isFalse,
    );
    expect(RolePermissionPolicy.forRole('superadmin'), isEmpty);
    expect(RolePermissionPolicy.forRole(null), isEmpty);
  });

  test(
    'autorización online, denegación y cambio obligatorio de contraseña',
    () async {
      final gateway = _Sessions();
      final authorizer = SessionOperationAuthorizer(
        ValidateSessionUseCase(gateway: gateway),
      );
      expect(await authorizer.require({AppPermission.salesCreate}), 'user-1');
      await expectLater(
        authorizer.require({AppPermission.productsCreate}),
        throwsA(isA<UserFacingException>()),
      );
      await expectLater(
        authorizer.require({AppPermission.purchasesManage}),
        throwsA(isA<UserFacingException>()),
      );
      gateway.role = 'admin';
      expect(
        await authorizer.require({AppPermission.businessConfigure}),
        'user-1',
      );
      expect(
        await authorizer.require({AppPermission.purchasesManage}),
        'user-1',
      );
      gateway.requiresPasswordChange = true;
      await expectLater(
        authorizer.require({AppPermission.salesCreate}),
        throwsA(isA<UserFacingException>()),
      );
    },
  );

  test('solo operaciones explícitas admiten autorización offline', () async {
    final gateway = _Sessions()..unavailable = true;
    final authorizer = SessionOperationAuthorizer(
      ValidateSessionUseCase(gateway: gateway),
    );
    await expectLater(
      authorizer.require({AppPermission.salesCreate}),
      throwsA(isA<UserFacingException>()),
    );
    expect(
      await authorizer.require({AppPermission.salesCreate}, allowOffline: true),
      'user-1',
    );
    gateway.cachedAt = DateTime.now().subtract(const Duration(hours: 25));
    await expectLater(
      authorizer.require({AppPermission.salesCreate}, allowOffline: true),
      throwsA(isA<UserFacingException>()),
    );
  });
}

class _Sessions implements SessionValidationGateway {
  @override
  String? currentAuthUserId = 'user-1';

  @override
  bool requiresPasswordChange = false;

  String role = 'operador';
  bool unavailable = false;
  DateTime cachedAt = DateTime.now();

  @override
  Future<String?> readActiveRole(String authUserId) async {
    if (unavailable) throw const SessionValidationUnavailable();
    return role;
  }

  @override
  Future<bool> canStartOrganizationSignup(String authUserId) async => false;

  @override
  Future<Set<AppPermission>?> readEffectivePermissions(
    String authUserId,
  ) async {
    if (unavailable) throw const SessionValidationUnavailable();
    return RolePermissionPolicy.forRole(role);
  }

  @override
  Future<CachedSessionAuthorization?> readCachedAuthorization(
    String authUserId,
  ) async => CachedSessionAuthorization(
    authUserId: 'user-1',
    role: role,
    validatedAt: cachedAt,
    permissions: RolePermissionPolicy.forRole(role),
  );

  @override
  Future<void> saveAuthorization(
    CachedSessionAuthorization authorization,
  ) async {}

  @override
  Future<void> clearCachedAuthorization(String expectedAuthUserId) async {}

  @override
  Future<void> invalidateSession(String expectedAuthUserId) async {
    currentAuthUserId = null;
  }
}
