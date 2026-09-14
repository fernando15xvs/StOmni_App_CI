import 'product_form_catalog.dart';

class MerchandiseEntryCatalog {
  final List<ProductWarehouseOption> warehouses;
  final List<ProductSupplierOption> activeSuppliers;

  MerchandiseEntryCatalog({
    required Iterable<ProductWarehouseOption> warehouses,
    required Iterable<ProductSupplierOption> activeSuppliers,
  }) : warehouses = List<ProductWarehouseOption>.unmodifiable(warehouses),
       activeSuppliers = List<ProductSupplierOption>.unmodifiable(activeSuppliers);
}

abstract interface class MerchandiseEntryCatalogGateway {
  Future<MerchandiseEntryCatalog> load();
}

class LoadMerchandiseEntryCatalogUseCase {
  final MerchandiseEntryCatalogGateway _gateway;

  const LoadMerchandiseEntryCatalogUseCase(this._gateway);

  Future<MerchandiseEntryCatalog> execute() => _gateway.load();
}
