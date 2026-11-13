import 'dart:convert';

import 'package:core_logic/auth/data/tenant_authorization_cache.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const companyA = '00000000-0000-0000-0000-000000000001';
  const companyB = '00000000-0000-0000-0000-000000000002';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TenantAuthorizationSnapshot valid(String organization) =>
      TenantAuthorizationSnapshot(
        authUserId: 'user-1',
        organizationId: organization,
        role: 'operador',
        validatedAt: DateTime.now().toUtc(),
        permissions: const {AppPermission.salesCreate},
      );

  test(
    'v3 saves only selected tenant and typed restricted permissions',
    () async {
      await TenantAuthorizationCache.save(valid(companyA));
      final loaded = await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyA,
      );
      expect(loaded, isNotNull);
      expect(loaded!.organizationId, companyA);
      expect(loaded.role, 'operador');
      expect(loaded.permissions, {AppPermission.salesCreate});
      expect(loaded.toMap()['schema_version'], 3);
      expect(loaded.toMap().containsKey('access_token'), isFalse);
    },
  );

  test('cache does not grant authorization to another tenant', () async {
    await TenantAuthorizationCache.save(valid(companyA));
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyB,
      ),
      isNull,
    );
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-2',
        organizationId: companyA,
      ),
      isNull,
    );
  });

  test('two tenants keep different snapshots without overwriting', () async {
    await TenantAuthorizationCache.save(valid(companyA));
    await TenantAuthorizationCache.save(
      TenantAuthorizationSnapshot(
        authUserId: 'user-1',
        organizationId: companyB,
        role: 'admin',
        validatedAt: DateTime.now().toUtc(),
        permissions: const {AppPermission.businessConfigure},
      ),
    );

    final a = await TenantAuthorizationCache.load(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    final b = await TenantAuthorizationCache.load(
      authUserId: 'user-1',
      organizationId: companyB,
    );
    expect(a?.role, 'operador');
    expect(b?.role, 'admin');
    expect(a!.permissions.contains(AppPermission.businessConfigure), isFalse);
    expect(b!.permissions.contains(AppPermission.businessConfigure), isTrue);
  });

  test('tenant-specific purge does not disturb other tenant', () async {
    await TenantAuthorizationCache.save(valid(companyA));
    await TenantAuthorizationCache.save(valid(companyB));
    await TenantAuthorizationCache.clearForTenant(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyA,
      ),
      isNull,
    );
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyB,
      ),
      isNotNull,
    );
    await TenantAuthorizationCache.clearAll();
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyB,
      ),
      isNull,
    );
  });

  test('v2 global snapshots cannot be used as a v3 tenant snapshot', () async {
    SharedPreferences.setMockInitialValues({
      'auth_validated_session_v2': jsonEncode({
        'schema_version': 2,
        'auth_user_id': 'user-1',
        'role': 'admin',
      }),
    });
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyA,
      ),
      isNull,
    );
  });

  test('unauthorized role or permission escalation invalidates snapshot', () {
    final map = valid(companyA).toMap();
    map['role'] = 'admin_from_header';
    expect(
      () => TenantAuthorizationSnapshot.fromMap(map),
      throwsFormatException,
    );
    map['role'] = 'operador';
    map['permissions'] = ['business.configure'];
    expect(
      () => TenantAuthorizationSnapshot.fromMap(map),
      throwsFormatException,
    );
  });

  test('expired and future records cannot be used offline', () {
    final old = valid(companyA).toMap();
    old['validated_at'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 25))
        .toIso8601String();
    final expired = TenantAuthorizationSnapshot.fromMap(old);
    expect(
      expired.isValidFor('user-1', companyA, DateTime.now().toUtc()),
      isFalse,
    );

    final future = valid(companyA).toMap();
    future['validated_at'] = DateTime.now()
        .toUtc()
        .add(const Duration(minutes: 6))
        .toIso8601String();
    expect(
      TenantAuthorizationSnapshot.fromMap(
        future,
      ).isValidFor('user-1', companyA, DateTime.now().toUtc()),
      isFalse,
    );
  });

  test('malformed, missing or cross-user records fail closed', () async {
    final invalid = valid(companyA).toMap();
    invalid['organization_id'] = companyB;
    SharedPreferences.setMockInitialValues({
      'auth_validated_session_v3:user-1:$companyA': jsonEncode(invalid),
    });
    expect(
      await TenantAuthorizationCache.load(
        authUserId: 'user-1',
        organizationId: companyA,
      ),
      isNull,
    );
    expect(
      () => TenantAuthorizationSnapshot.fromMap({
        ...valid(companyA).toMap(),
        'organization_id': 'bad-id',
      }),
      throwsFormatException,
    );
  });
}
