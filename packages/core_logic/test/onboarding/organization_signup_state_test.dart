import 'package:core_logic/onboarding/domain/organization_signup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('revoked signup state does not authorize organization setup', () {
    final state = OrganizationSignupState.fromJson(const {
      'state': 'access_revoked',
      'eligible': false,
      'organization_id': null,
    });
    expect(state.kind, OrganizationSignupStateKind.accessRevoked);
    expect(state.eligible, isFalse);
    expect(state.organizationId, isNull);
    expect(state.displayName, isNull);
  });

  test('active and unattached signup states remain compatible', () {
    final existing = OrganizationSignupState.fromJson(const {
      'state': 'attached',
      'eligible': false,
      'organization_id': '00000000-0000-0000-0000-000000000001',
    });
    final eligible = OrganizationSignupState.fromJson(const {
      'state': 'eligible',
      'eligible': true,
    });
    expect(existing.kind, OrganizationSignupStateKind.attached);
    expect(eligible.kind, OrganizationSignupStateKind.eligible);
  });
}
