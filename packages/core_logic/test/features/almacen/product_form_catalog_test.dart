import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCatalogGateway implements ProductFormCatalogGateway {
  _FakeCatalogGateway(this.catalog);

  final ProductFormCatalog catalog;
  int loadCalls = 0;

  @override
  Future<ProductFormCatalog> load() async {
    loadCalls++;
    return catalog;
  }
}

void main() {
  group('LoadProductFormCatalogUseCase', () {
    test('expone almacenes y proveedores tipados al consumidor', () async {
      final catalog = ProductFormCatalog(
        warehouses: const [
          ProductWarehouseOption(id: 1, name: 'Principal'),
          ProductWarehouseOption(id: 2, name: 'Sucursal Norte'),
        ],
        suppliers: const [
          ProductSupplierOption(id: 10, name: 'Proveedor A'),
        ],
      );
      final gateway = _FakeCatalogGateway(catalog);
      final useCase = LoadProductFormCatalogUseCase(gateway);

      final result = await useCase.execute();

      expect(gateway.loadCalls, 1);
      expect(result.warehouses.map((item) => item.id), [1, 2]);
      expect(result.warehouses.map((item) => item.name), [
        'Principal',
        'Sucursal Norte',
      ]);
      expect(result.suppliers.single.id, 10);
      expect(result.suppliers.single.name, 'Proveedor A');
    });

    test('mantiene una conversión legacy acotada para la UI móvil actual', () {
      const warehouse = ProductWarehouseOption(id: 7, name: 'Central');
      const supplier = ProductSupplierOption(id: 15, name: 'Marca Uno');

      expect(warehouse.toLegacyMap(), {'id': 7, 'nombre': 'Central'});
      expect(supplier.toLegacyMap(), {'id': 15, 'nombre': 'Marca Uno'});
    });
  });
}
