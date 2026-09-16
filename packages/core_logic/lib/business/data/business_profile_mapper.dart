import '../domain/business_profile.dart';

class BusinessProfileMapper {
  const BusinessProfileMapper._();

  static BusinessProfile decode(Map<String, dynamic> row) {
    final id = row['business_id']?.toString().trim() ?? '';
    final rawCapabilities = row['capabilities'];
    final revision = row['revision'];
    if (id.isEmpty ||
        rawCapabilities is! Map ||
        revision is! int ||
        revision < 0 ||
        row['supports_capability_settings'] is! bool) {
      throw const FormatException(
        'Perfil de negocio inválido o no compatible.',
      );
    }

    bool read(String key) {
      final value = rawCapabilities[key];
      if (value is! bool) throw FormatException('Capacidad inválida: $key');
      return value;
    }

    final capabilities = BusinessCapabilities(
      inventoryEnabled: read('inventory_enabled'),
      multipleBranches: read('multiple_branches'),
      multipleWarehouses: read('multiple_warehouses'),
      creditSales: read('credit_sales'),
      electronicInvoicing: read('electronic_invoicing'),
      supplierManagement: read('supplier_management'),
      purchaseManagement: read('purchase_management'),
      lotTracking: read('lot_tracking'),
      expiryTracking: read('expiry_tracking'),
      variants: read('variants'),
      services: read('services'),
      serialNumberTracking: read('serial_number_tracking'),
    );
    if (!capabilities.supportedByCurrentBackend) {
      throw const FormatException(
        'El perfil requiere una combinación de capacidades no soportada.',
      );
    }
    return BusinessProfile(
      businessId: id,
      displayName: row['display_name']?.toString() ?? '',
      capabilities: capabilities,
      revision: revision,
      supportsCapabilitySettings: row['supports_capability_settings'] == true,
    );
  }

  static Map<String, dynamic> encodeCapabilities(BusinessCapabilities value) =>
      {
        'inventory_enabled': value.inventoryEnabled,
        'multiple_branches': value.multipleBranches,
        'multiple_warehouses': value.multipleWarehouses,
        'credit_sales': value.creditSales,
        'electronic_invoicing': value.electronicInvoicing,
        'supplier_management': value.supplierManagement,
        'purchase_management': value.purchaseManagement,
        'lot_tracking': value.lotTracking,
        'expiry_tracking': value.expiryTracking,
        'variants': value.variants,
        'services': value.services,
        'serial_number_tracking': value.serialNumberTracking,
      };

  static Map<String, dynamic> encode(BusinessProfile profile) => {
    'business_id': profile.businessId,
    'display_name': profile.displayName,
    'revision': profile.revision,
    'supports_capability_settings': profile.supportsCapabilitySettings,
    'capabilities': encodeCapabilities(profile.capabilities),
  };
}
