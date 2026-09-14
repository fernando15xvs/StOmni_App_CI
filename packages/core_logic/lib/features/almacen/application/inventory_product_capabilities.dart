import '../domain/product_capabilities.dart';
import 'inventory_catalog_use_case.dart';

extension InventoryCatalogItemCapabilities on InventoryCatalogItem {
  ProductCapabilities get legacyCapabilities => ProductCapabilities.legacy(
    commercialProfile: commercialProfile,
    allowSaleWithoutStock: product.permitirSinStock,
  );

  ProductCapabilities capabilitiesFor(ProductCapabilityPolicy policy) {
    final configured = policy.resolve(
      productId: product.id,
      category: product.categoria,
    );
    return configured.isCompatibleWith(commercialProfile)
        ? configured
        : legacyCapabilities;
  }

  bool canSellPresentation(
    String presentationCode, {
    ProductCapabilityPolicy? policy,
  }) {
    final capabilities = policy == null
        ? legacyCapabilities
        : capabilitiesFor(policy);
    return commercialProfile.supports(presentationCode) &&
        capabilities.supportsPresentation(presentationCode);
  }
}
