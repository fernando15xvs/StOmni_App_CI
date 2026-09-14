import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/business/application/business_module_policy.dart';
import 'package:core_logic/business/domain/business_profile.dart';

void main() {
  test('core modules stay available', () {
    const capabilities = BusinessCapabilities(
      inventoryEnabled: false,
      multipleWarehouses: false,
      purchaseManagement: false,
      electronicInvoicing: false,
      services: false,
      variants: false,
    );

    expect(BusinessModulePolicy.isEnabled(capabilities, BusinessModule.dashboard), isTrue);
    expect(BusinessModulePolicy.isEnabled(capabilities, BusinessModule.sales), isTrue);
    expect(BusinessModulePolicy.isEnabled(capabilities, BusinessModule.catalog), isTrue);
    expect(BusinessModulePolicy.isEnabled(capabilities, BusinessModule.customers), isTrue);
    expect(BusinessModulePolicy.isEnabled(capabilities, BusinessModule.moduleSettings), isTrue);
  });

  test('optional modules follow capabilities', () {
    const disabled = BusinessCapabilities(
      inventoryEnabled: false,
      multipleWarehouses: false,
      purchaseManagement: false,
      electronicInvoicing: false,
      services: false,
      variants: false,
    );
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.inventory), isFalse);
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.stockTransfers), isFalse);
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.purchases), isFalse);
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.services), isFalse);
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.variants), isFalse);
    expect(BusinessModulePolicy.isEnabled(disabled, BusinessModule.electronicDocuments), isFalse);

    const enabled = BusinessCapabilities(
      purchaseManagement: true,
      electronicInvoicing: true,
      services: true,
      variants: true,
    );
    expect(BusinessModulePolicy.isEnabled(enabled, BusinessModule.inventory), isTrue);
    expect(BusinessModulePolicy.isEnabled(enabled, BusinessModule.purchases), isTrue);
    expect(BusinessModulePolicy.isEnabled(enabled, BusinessModule.services), isTrue);
    expect(BusinessModulePolicy.isEnabled(enabled, BusinessModule.variants), isTrue);
    expect(BusinessModulePolicy.isEnabled(enabled, BusinessModule.electronicDocuments), isTrue);
  });

  test('traceability configuration remains reachable while inventory is enabled', () {
    const capabilities = BusinessCapabilities(
      lotTracking: false,
      serialNumberTracking: false,
    );
    expect(
      BusinessModulePolicy.isEnabled(capabilities, BusinessModule.traceability),
      isTrue,
    );
  });
}