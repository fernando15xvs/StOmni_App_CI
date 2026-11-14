import 'package:core_logic/business/data/tenant_business_profile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const companyA = '00000000-0000-0000-0000-000000000021';
  const companyB = '00000000-0000-0000-0000-000000000022';

  Map<String, dynamic> serverProfile({
    String organizationId = companyA,
    bool creditSales = true,
    bool electronicInvoicing = true,
  }) => {
    'organization_id': organizationId,
    'business_id': '875',
    'display_name': 'Comercio local',
    'revision': 2,
    'supports_capability_settings': true,
    'capabilities': <String, dynamic>{
      'inventory_enabled': true,
      'multiple_branches': true,
      'multiple_warehouses': true,
      'credit_sales': creditSales,
      'electronic_invoicing': electronicInvoicing,
      'supplier_management': true,
      'purchase_management': false,
      'lot_tracking': false,
      'expiry_tracking': false,
      'variants': false,
      'services': false,
      'serial_number_tracking': false,
    },
  };

  test('accepts selected business with a separate configuration ID', () {
    final profile = TenantBusinessProfileGateway.decodeSelectedBusiness(
      serverProfile(),
      organizationId: companyA,
    );
    expect(profile.businessId, '875');
    expect(profile.revision, 2);
    expect(profile.displayName, 'Comercio local');
    expect(profile.capabilities.creditSales, isTrue);
  });

  test('does not treat business_id as organization_id', () {
    final profile = TenantBusinessProfileGateway.decodeSelectedBusiness(
      serverProfile(),
      organizationId: companyA,
    );
    expect(profile.businessId, isNot(companyA));
  });

  test('rejects response from another selected organization', () {
    expect(
      () => TenantBusinessProfileGateway.decodeSelectedBusiness(
        serverProfile(organizationId: companyB),
        organizationId: companyA,
      ),
      throwsStateError,
    );
  });

  test('missing tenant identity fails closed despite a valid business', () {
    final payload = serverProfile()..remove('organization_id');
    expect(
      () => TenantBusinessProfileGateway.decodeSelectedBusiness(
        payload,
        organizationId: companyA,
      ),
      throwsStateError,
    );
  });

  test('invalid response never falls back to unscoped default', () {
    for (final value in [null, <Object>[], 'untrusted', 42]) {
      expect(
        () => TenantBusinessProfileGateway.decodeSelectedBusiness(
          value,
          organizationId: companyA,
        ),
        throwsFormatException,
      );
    }
  });

  test('capability policy stays selected-company-specific', () {
    final a = TenantBusinessProfileGateway.decodeSelectedBusiness(
      serverProfile(),
      organizationId: companyA,
    );
    final b = TenantBusinessProfileGateway.decodeSelectedBusiness(
      serverProfile(
        organizationId: companyB,
        creditSales: false,
        electronicInvoicing: false,
      ),
      organizationId: companyB,
    );
    expect(a.capabilities.creditSales, isTrue);
    expect(b.capabilities.creditSales, isFalse);
    expect(a.capabilities.electronicInvoicing, isTrue);
    expect(b.capabilities.electronicInvoicing, isFalse);
  });

  test('a business capability with an invalid type is rejected', () {
    final payload = serverProfile();
    (payload['capabilities'] as Map<String, dynamic>)['credit_sales'] = 'true';
    expect(
      () => TenantBusinessProfileGateway.decodeSelectedBusiness(
        payload,
        organizationId: companyA,
      ),
      throwsFormatException,
    );
  });

  test('unsupported capabilities cannot be trusted from server payload', () {
    final payload = serverProfile();
    (payload['capabilities'] as Map<String, dynamic>)['supplier_management'] =
        false;
    expect(
      () => TenantBusinessProfileGateway.decodeSelectedBusiness(
        payload,
        organizationId: companyA,
      ),
      throwsFormatException,
    );
  });

  test('negative profile revision is rejected even with a valid tenant', () {
    final payload = serverProfile()..['revision'] = -1;
    expect(
      () => TenantBusinessProfileGateway.decodeSelectedBusiness(
        payload,
        organizationId: companyA,
      ),
      throwsFormatException,
    );
  });
}
