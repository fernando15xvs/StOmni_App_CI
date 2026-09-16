import '../domain/business_profile.dart';

enum BusinessModule {
  dashboard,
  sales,
  catalog,
  services,
  traceability,
  variants,
  pricing,
  inventory,
  customers,
  suppliers,
  purchases,
  electronicDocuments,
  reports,
  metrics,
  permissions,
  moduleSettings,
  balance,
  stockTransfers,
}

class BusinessModulePolicy {
  const BusinessModulePolicy._();

  static bool isEnabled(BusinessCapabilities c, BusinessModule module) {
    return switch (module) {
      BusinessModule.dashboard ||
      BusinessModule.sales ||
      BusinessModule.catalog ||
      BusinessModule.customers ||
      BusinessModule.reports ||
      BusinessModule.metrics ||
      BusinessModule.permissions ||
      BusinessModule.moduleSettings ||
      BusinessModule.balance => true,
      BusinessModule.services => c.services,
      BusinessModule.traceability => c.inventoryEnabled,
      BusinessModule.variants => c.variants,
      BusinessModule.pricing => true,
      BusinessModule.inventory ||
      BusinessModule.stockTransfers => c.inventoryEnabled,
      BusinessModule.suppliers => c.supplierManagement,
      BusinessModule.purchases => c.purchaseManagement,
      BusinessModule.electronicDocuments => c.electronicInvoicing,
    };
  }

  static Set<BusinessModule> enabledModules(BusinessCapabilities capabilities) {
    return Set.unmodifiable(
      BusinessModule.values.where((module) => isEnabled(capabilities, module)),
    );
  }
}
