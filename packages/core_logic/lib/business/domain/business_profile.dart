/// Capacidades funcionales, no sectores ni permisos de usuario.
class BusinessCapabilities {
  const BusinessCapabilities({
    this.inventoryEnabled = true,
    this.multipleBranches = true,
    this.multipleWarehouses = true,
    this.creditSales = true,
    this.electronicInvoicing = true,
    this.supplierManagement = true,
    this.purchaseManagement = false,
    this.lotTracking = false,
    this.expiryTracking = false,
    this.variants = false,
    this.services = false,
    this.serialNumberTracking = false,
  });

  final bool inventoryEnabled;
  final bool multipleBranches;
  final bool multipleWarehouses;
  final bool creditSales;
  final bool electronicInvoicing;
  final bool supplierManagement;
  final bool purchaseManagement;
  final bool lotTracking;
  final bool expiryTracking;
  final bool variants;
  final bool services;
  final bool serialNumberTracking;

  /// El backend actual soporta capacidades desactivadas. Sólo se rechazan
  /// combinaciones que violan invariantes estructurales del dominio.
  bool get supportedByCurrentBackend =>
      supplierManagement &&
      (!expiryTracking || lotTracking) &&
      (inventoryEnabled ||
          (!purchaseManagement &&
              !lotTracking &&
              !expiryTracking &&
              !serialNumberTracking &&
              !multipleWarehouses));

  BusinessCapabilities withSales({
    bool? creditSales,
    bool? electronicInvoicing,
  }) => BusinessCapabilities(
    inventoryEnabled: inventoryEnabled,
    multipleBranches: multipleBranches,
    multipleWarehouses: multipleWarehouses,
    creditSales: creditSales ?? this.creditSales,
    electronicInvoicing: electronicInvoicing ?? this.electronicInvoicing,
    supplierManagement: supplierManagement,
    purchaseManagement: purchaseManagement,
    lotTracking: lotTracking,
    expiryTracking: expiryTracking,
    variants: variants,
    services: services,
    serialNumberTracking: serialNumberTracking,
  );
}

class BusinessProfile {
  const BusinessProfile({
    required this.businessId,
    required this.displayName,
    required this.capabilities,
    required this.revision,
    required this.supportsCapabilitySettings,
  });

  final String businessId;
  final String displayName;
  final BusinessCapabilities capabilities;
  final int revision;
  /// False en servidores que aún no instalaron la migración aditiva.
  final bool supportsCapabilitySettings;
}
