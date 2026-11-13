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

  test('ambiguous membership requires explicit selection and leaks no company', () {
    final state = OrganizationSignupState.fromJson(const {
      'state': 'selection_required',
      'eligible': false,
      'organization_id': '00000000-0000-0000-0000-000000000001',
      'display_name': 'Should not be exposed',
    });
    expect(state.kind, OrganizationSignupStateKind.selectionRequired);
    expect(state.eligible, isFalse);
    expect(state.organizationId, isNull);
    expect(state.displayName, isNull);
  });

  test('revoked account state does not trust server-provided metadata', () {
    final state = OrganizationSignupState.fromJson(const {
      'state': 'access_revoked',
      'eligible': false,
      'organization_id': '00000000-0000-0000-0000-000000000001',
      'display_name': 'Forbidden',
    });
    expect(state.organizationId, isNull);
    expect(state.displayName, isNull);
  });

  test('active company membership decodes only valid role and tenant id', () {
    final entry = OrganizationMembership.fromJson(const {
      'organization_id': '00000000-0000-0000-0000-000000000001',
      'display_name': 'Empresa A',
      'base_role': 'admin',
    });
    expect(entry.organizationId, '00000000-0000-0000-0000-000000000001');
    expect(entry.displayName, 'Empresa A');
    expect(entry.baseRole, 'admin');
    expect(() => OrganizationMembership.fromJson(const {
      'organization_id': 'bad',
      'display_name': 'Empresa A',
      'base_role': 'admin',
    }), throwsFormatException);
    expect(() => OrganizationMembership.fromJson(const {
      'organization_id': '00000000-0000-0000-0000-000000000001',
      'display_name': 'Empresa A',
      'base_role': 'owner_from_header',
    }), throwsFormatException);
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
