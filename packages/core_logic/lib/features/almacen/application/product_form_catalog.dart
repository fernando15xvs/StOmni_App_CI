class ProductWarehouseOption {
  const ProductWarehouseOption({required this.id, required this.name});

  final int id;
  final String name;

  Map<String, dynamic> toLegacyMap() => <String, dynamic>{
    'id': id,
    'nombre': name,
  };
}

class ProductSupplierOption {
  const ProductSupplierOption({required this.id, required this.name});

  final int id;
  final String name;

  Map<String, dynamic> toLegacyMap() => <String, dynamic>{
    'id': id,
    'nombre': name,
  };
}

class ProductFormCatalog {
  ProductFormCatalog({
    required Iterable<ProductWarehouseOption> warehouses,
    required Iterable<ProductSupplierOption> suppliers,
  }) : warehouses = List<ProductWarehouseOption>.unmodifiable(warehouses),
       suppliers = List<ProductSupplierOption>.unmodifiable(suppliers);

  final List<ProductWarehouseOption> warehouses;
  final List<ProductSupplierOption> suppliers;
}

abstract interface class ProductFormCatalogGateway {
  Future<ProductFormCatalog> load();
}

class LoadProductFormCatalogUseCase {
  const LoadProductFormCatalogUseCase(this._gateway);

  final ProductFormCatalogGateway _gateway;

  Future<ProductFormCatalog> execute() => _gateway.load();
}
