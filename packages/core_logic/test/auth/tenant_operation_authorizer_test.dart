import 'dart:async';

import 'package:core_logic/auth/application/tenant_operation_authorizer.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/errors/user_facing_exception.dart';
import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const user = '00000000-0000-0000-0000-000000000011';
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  TenantRequestScope scope(String org) =>
      TenantRequestScope(authUserId: user, organizationId: org);

  TenantVerifiedPermissions parsed(
    String org,
    String baseRole, {
    List<String>? codes,
  }) => TenantVerifiedPermissions.fromServer(
    VerifiedTenantRequestContext(
      organizationId: org,
      baseRole: baseRole,
    ),
    {
      'supported': true,
      'employee_id': 17,
      'role': baseRole == 'admin' ? 'admin' : 'operator',
      'permissions': codes ?? ['sales.create', 'tenant.read'],
    },
  );

  test('admin permissions are verified under selected A only', () {
    final verified = parsed(
      orgA,
      'admin',
      codes: ['sales.create', 'business.configure', 'tenant.read'],
    );
    expect(verified.organizationId, orgA);
    expect(verified.baseRole, 'admin');
    expect(verified.employeeId, 17);
    expect(verified.permissions, {
      AppPermission.salesCreate,
      AppPermission.businessConfigure,
    });
  });

  test('operator permissions are limited to B base role', () {
    final verified = parsed(orgB, 'operador');
    expect(verified.permissions, {AppPermission.salesCreate});
    expect(verified.permissions.contains(AppPermission.businessConfigure),
        isFalse);
  });

  test('server role mismatch fails closed rather than inheriting A admin', () {
    expect(
      () => TenantVerifiedPermissions.fromServer(
        const VerifiedTenantRequestContext(
          organizationId: orgB,
          baseRole: 'operador',
        ),
        {
          'supported': true,
          'employee_id': 17,
          'role': 'admin',
          'permissions': ['sales.create'],
        },
      ),
      throwsFormatException,
    );
  });

  test('operator business.configure escalation is denied', () {
    expect(
      () => parsed(
        orgB,
        'operador',
        codes: ['business.configure'],
      ),
      throwsStateError,
    );
  });

  test('malformed permissions and missing server support are denied', () {
    final context = const VerifiedTenantRequestContext(
      organizationId: orgA,
      baseRole: 'admin',
    );
    for (final payload in [
      null,
      <String, dynamic>{'supported': false},
      <String, dynamic>{
        'supported': true,
        'employee_id': 0,
        'role': 'admin',
        'permissions': <String>[],
      },
      <String, dynamic>{
        'supported': true,
        'employee_id': 17,
        'role': 'admin',
        'permissions': <Object>['sales.create', 19],
      },
    ]) {
      expect(
        () => TenantVerifiedPermissions.fromServer(context, payload),
        throwsFormatException,
      );
    }
  });

  test('tenant authorizer verifies online permission and actor', () async {
    final auth = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgA,
      verifyPermissions: (_) async => parsed(orgA, 'admin'),
    );
    expect(
      await auth.require({AppPermission.salesCreate}),
      user,
    );
    expect(auth.currentAuthUserId, user);
  });

  test('operator cannot use an admin permission from another company',
      () async {
    final auth = TenantOperationAuthorizer(
      scope: scope(orgB),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgB,
      verifyPermissions: (_) async => parsed(orgB, 'operador'),
    );
    await expectLater(
      auth.require({AppPermission.businessConfigure}),
      throwsA(isA<UserFacingException>()),
    );
  });

  test('offline tenant auth stays disabled until v3 cache integration',
      () async {
    var contacted = false;
    final auth = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgA,
      verifyPermissions: (_) async {
        contacted = true;
        return parsed(orgA, 'admin');
      },
    );
    await expectLater(
      auth.require({AppPermission.salesCreate}, allowOffline: true),
      throwsA(isA<UserFacingException>()),
    );
    expect(contacted, isFalse);
  });

  test('revoked server context cannot certify another organization',
      () async {
    final auth = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgA,
      verifyPermissions: (_) async => parsed(orgB, 'operador'),
    );
    await expectLater(
      auth.require({AppPermission.salesCreate}),
      throwsA(isA<UserFacingException>()),
    );
  });

  test('changing Auth while permissions load discards stale response',
      () async {
    String? active = user;
    final gate = Completer<TenantVerifiedPermissions>();
    final auth = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => active,
      currentSelectedOrganizationId: () => orgA,
      verifyPermissions: (_) => gate.future,
    );
    final pending = auth.require({AppPermission.salesCreate});
    active = 'another-user';
    gate.complete(parsed(orgA, 'admin'));
    await expectLater(pending, throwsStateError);
  });

  test('switching companies during permissions load discards response',
      () async {
    String? selected = orgA;
    final gate = Completer<TenantVerifiedPermissions>();
    final auth = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => selected,
      verifyPermissions: (_) => gate.future,
    );
    final pending = auth.require({AppPermission.salesCreate});
    selected = orgB;
    gate.complete(parsed(orgA, 'admin'));
    await expectLater(pending, throwsStateError);
  });

  test('two windows with same Auth identity retain different permissions',
      () async {
    final adminWindow = TenantOperationAuthorizer(
      scope: scope(orgA),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgA,
      verifyPermissions: (_) async => parsed(
        orgA,
        'admin',
        codes: ['business.configure'],
      ),
    );
    final operatorWindow = TenantOperationAuthorizer(
      scope: scope(orgB),
      currentAuthUserId: () => user,
      currentSelectedOrganizationId: () => orgB,
      verifyPermissions: (_) async => parsed(orgB, 'operador'),
    );
    expect(
      await adminWindow.require({AppPermission.businessConfigure}),
      user,
    );
    await expectLater(
      operatorWindow.require({AppPermission.businessConfigure}),
      throwsA(isA<UserFacingException>()),
    );
    expect(
      await operatorWindow.require({AppPermission.salesCreate}),
      user,
    );
  });
}
