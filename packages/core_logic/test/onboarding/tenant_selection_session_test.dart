import 'dart:async';

import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:core_logic/onboarding/application/tenant_selection_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  VerifiedTenantRequestContext verified(String org, String role) =>
      VerifiedTenantRequestContext(organizationId: org, baseRole: role);

  test(
    'successful selection takes server-validated role, not a client role',
    () async {
      final selection = TenantSelectionSession(
        currentAuthUserId: () => 'user-a',
      );
      final result = await selection.verifySelection(
        organizationId: orgA,
        verify: (scope) async {
          expect(scope.authUserId, 'user-a');
          expect(scope.organizationId, orgA);
          expect(selection.activeOrganizationId, isNull);
          expect(selection.requestOrganizationId, orgA);
          return verified(orgA, 'operador');
        },
      );
      expect(result.baseRole, 'operador');
      expect(selection.activeOrganizationId, orgA);
      expect(selection.activeBaseRole, 'operador');
      expect(selection.isVerifying, isFalse);
    },
  );

  test('auth signed out cannot begin company selection', () async {
    final selection = TenantSelectionSession(currentAuthUserId: () => null);
    var invoked = false;
    await expectLater(
      selection.verifySelection(
        organizationId: orgA,
        verify: (scope) async {
          invoked = true;
          return verified(orgA, 'admin');
        },
      ),
      throwsStateError,
    );
    expect(invoked, isFalse);
  });

  test('server response for a foreign organization is rejected', () async {
    final selection = TenantSelectionSession(currentAuthUserId: () => 'user-a');
    await expectLater(
      selection.verifySelection(
        organizationId: orgA,
        verify: (scope) async => verified(orgB, 'admin'),
      ),
      throwsStateError,
    );
    expect(selection.activeOrganizationId, isNull);
  });

  test('role from untrusted client cannot be activated', () async {
    final selection = TenantSelectionSession(currentAuthUserId: () => 'user-a');
    await expectLater(
      selection.verifySelection(
        organizationId: orgA,
        verify: (scope) async => verified(orgA, 'super_admin'),
      ),
      throwsStateError,
    );
    expect(selection.activeBaseRole, isNull);
  });

  test('invalid company UUID does not create pending request', () async {
    final selection = TenantSelectionSession(currentAuthUserId: () => 'user-a');
    await expectLater(
      selection.verifySelection(
        organizationId: '../../company',
        verify: (scope) async => verified(orgA, 'admin'),
      ),
      throwsFormatException,
    );
    expect(selection.isVerifying, isFalse);
  });

  test(
    'later B selection wins and stale A response cannot replace it',
    () async {
      final pendingA = Completer<VerifiedTenantRequestContext>();
      final selection = TenantSelectionSession(
        currentAuthUserId: () => 'user-a',
      );
      final old = selection.verifySelection(
        organizationId: orgA,
        verify: (scope) => pendingA.future,
      );
      expect(selection.requestOrganizationId, orgA);
      expect(selection.activeOrganizationId, isNull);

      final next = selection.verifySelection(
        organizationId: orgB,
        verify: (scope) async => verified(orgB, 'operador'),
      );
      expect((await next).organizationId, orgB);
      pendingA.complete(verified(orgA, 'admin'));
      await expectLater(old, throwsStateError);
      expect(selection.activeOrganizationId, orgB);
      expect(selection.activeBaseRole, 'operador');
    },
  );

  test('logout invalidates an outstanding selection verification', () async {
    final response = Completer<VerifiedTenantRequestContext>();
    final selection = TenantSelectionSession(currentAuthUserId: () => 'user-a');
    final pending = selection.verifySelection(
      organizationId: orgA,
      verify: (scope) => response.future,
    );
    selection.clear();
    response.complete(verified(orgA, 'admin'));
    await expectLater(pending, throwsStateError);
    expect(selection.requestOrganizationId, isNull);
    expect(selection.activeOrganizationId, isNull);
  });

  test(
    'auth switch during network response prevents stale tenant activation',
    () async {
      var user = 'user-a';
      final response = Completer<VerifiedTenantRequestContext>();
      final selection = TenantSelectionSession(currentAuthUserId: () => user);
      final pending = selection.verifySelection(
        organizationId: orgA,
        verify: (scope) => response.future,
      );
      user = 'user-b';
      response.complete(verified(orgA, 'admin'));
      await expectLater(pending, throwsStateError);
      expect(selection.activeOrganizationId, isNull);
    },
  );

  test(
    'two windows for same auth user keep separate independent selections',
    () async {
      final a = TenantSelectionSession(currentAuthUserId: () => 'shared-user');
      final b = TenantSelectionSession(currentAuthUserId: () => 'shared-user');
      await Future.wait([
        a.verifySelection(
          organizationId: orgA,
          verify: (scope) async => verified(orgA, 'admin'),
        ),
        b.verifySelection(
          organizationId: orgB,
          verify: (scope) async => verified(orgB, 'operador'),
        ),
      ]);
      expect(a.activeOrganizationId, orgA);
      expect(b.activeOrganizationId, orgB);
      a.clear();
      expect(b.activeOrganizationId, orgB);
    },
  );

  test('failed revalidation clears previous selected company', () async {
    final selection = TenantSelectionSession(currentAuthUserId: () => 'user-a');
    await selection.verifySelection(
      organizationId: orgA,
      verify: (scope) async => verified(orgA, 'admin'),
    );
    await expectLater(
      selection.verifySelection(
        organizationId: orgB,
        verify: (scope) async => throw StateError('revoked'),
      ),
      throwsStateError,
    );
    expect(selection.activeOrganizationId, isNull);
  });
}
