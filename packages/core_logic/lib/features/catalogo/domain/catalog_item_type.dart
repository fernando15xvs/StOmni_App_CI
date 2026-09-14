enum CatalogItemType {
  stockProduct('stock_product'),
  nonStockProduct('non_stock_product'),
  service('service'),
  bundle('bundle');

  const CatalogItemType(this.code);
  final String code;

  bool get isInventoriable => this == CatalogItemType.stockProduct;
  bool get isService => this == CatalogItemType.service;
  bool get isBundle => this == CatalogItemType.bundle;

  static CatalogItemType fromCode(Object? raw, {bool legacyService = false}) {
    final value = raw?.toString().trim().toLowerCase();
    if (value == null || value.isEmpty) {
      return legacyService ? CatalogItemType.service : CatalogItemType.stockProduct;
    }
    for (final item in values) {
      if (item.code == value) return item;
    }
    throw FormatException('Tipo de ítem de catálogo desconocido: $value');
  }
}