import 'dart:async';

import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const companyA = '00000000-0000-0000-0000-000000000001';
  const companyB = '00000000-0000-0000-0000-000000000002';

  test('tenant identifier must be a UUID before any request starts', () {
    expect(
      () => TenantRequestScope(
        authUserId: 'user-1',
        organizationId: 'other-company',
      ),
      throwsFormatException,
    );
    expect(
      () => TenantRequestScope(
        authUserId: '',
        organizationId: companyA,
      ),
      throwsFormatException,
    );
  });

  test('explicit tenant header is request-local, not a global role', () async {
    final scope = TenantRequestScope(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    String? observed;
    final result = await scope.execute<String>(
      currentAuthUserId: () => 'user-1',
      currentSelectedOrganizationId: () => companyA,
      request: (tenantId) async {
        observed = tenantId;
        return 'verified';
      },
    );
    expect(result, 'verified');
    expect(observed, companyA);
    expect(TenantRequestScope.organizationHeader, 'x-stomni-organization-id');
  });

  test('missing Auth or wrong tenant rejects without calling transport', () async {
    final scope = TenantRequestScope(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    var called = false;
    for (final values in [
      <String?>[null, companyA],
      <String?>['user-2', companyA],
      <String?>['user-1', null],
      <String?>['user-1', companyB],
    ]) {
      await expectLater(
        scope.execute<String>(
          currentAuthUserId: () => values[0],
          currentSelectedOrganizationId: () => values[1],
          request: (tenantId) async {
            called = true;
            return tenantId;
          },
        ),
        throwsStateError,
      );
    }
    expect(called, isFalse);
  });

  test('Auth change during an in-flight RPC invalidates its response', () async {
    final gate = Completer<void>();
    String? currentUser = 'user-1';
    final scope = TenantRequestScope(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    final pending = scope.execute<String>(
      currentAuthUserId: () => currentUser,
      currentSelectedOrganizationId: () => companyA,
      request: (tenantId) async {
        await gate.future;
        return tenantId;
      },
    );
    currentUser = 'user-2';
    gate.complete();
    await expectLater(pending, throwsStateError);
  });

  test('tenant switch while RPC runs must discard old company result', () async {
    final gate = Completer<void>();
    String? selected = companyA;
    final scope = TenantRequestScope(
      authUserId: 'user-1',
      organizationId: companyA,
    );
    final pending = scope.execute<String>(
      currentAuthUserId: () => 'user-1',
      currentSelectedOrganizationId: () => selected,
      request: (tenantId) async {
        await gate.future;
        return tenantId;
      },
    );
    selected = companyB;
    gate.complete();
    await expectLater(pending, throwsStateError);
  });

  test('two simultaneous sessions cannot overwrite each other headers', () async {
    final gateA = Completer<void>();
    final gateB = Completer<void>();
    final scopeA = TenantRequestScope(
      authUserId: 'shared-auth-user',
      organizationId: companyA,
    );
    final scopeB = TenantRequestScope(
      authUserId: 'shared-auth-user',
      organizationId: companyB,
    );
    final pendingA = scopeA.execute<String>(
      currentAuthUserId: () => 'shared-auth-user',
      currentSelectedOrganizationId: () => companyA,
      request: (tenantId) async {
        await gateA.future;
        return tenantId;
      },
    );
    final pendingB = scopeB.execute<String>(
      currentAuthUserId: () => 'shared-auth-user',
      currentSelectedOrganizationId: () => companyB,
      request: (tenantId) async {
        await gateB.future;
        return tenantId;
      },
    );
    gateB.complete();
    gateA.complete();
    expect(await Future.wait([pendingA, pendingB]), [companyA, companyB]);
  });

  test('server identity response must match the explicitly selected tenant', () {
    final verified = VerifiedTenantRequestContext.fromServer(
      {'organization_id': companyA, 'base_role': 'operador'},
      requestedOrganizationId: companyA,
    );
    expect(verified.organizationId, companyA);
    expect(verified.baseRole, 'operador');
    expect(
      () => VerifiedTenantRequestContext.fromServer(
        {'organization_id': companyB, 'base_role': 'admin'},
        requestedOrganizationId: companyA,
      ),
      throwsStateError,
    );
    expect(
      () => VerifiedTenantRequestContext.fromServer(
        {'organization_id': companyA, 'base_role': 'role_from_header'},
        requestedOrganizationId: companyA,
      ),
      throwsStateError,
    );
    expect(
      () => VerifiedTenantRequestContext.fromServer(
        null,
        requestedOrganizationId: companyA,
      ),
      throwsFormatException,
    );
  });
}
