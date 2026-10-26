import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/almacen/widgets/inventory_stock_filter.dart';

void main() {
  final products = <Map<String, dynamic>>[
    {'codigo': 'A', '_totalStock': 8},
    {'codigo': 'B', '_totalStock': 0},
    {'codigo': 'C', '_totalStock': -2},
    {'codigo': 'D', '_totalStock': null},
    {'codigo': 'E', '_totalStock': 3.0},
  ];

  test('Todos conserva el orden y productos de stock desconocido', () {
    expect(
      InventoryStockFiltering.apply(products, InventoryStockFilter.all),
      products,
    );
  });

  test('Con stock incluye únicamente existencias positivas', () {
    final result = InventoryStockFiltering.apply(
      products,
      InventoryStockFilter.available,
    );
    expect(result.map((p) => p['codigo']), ['A', 'E']);
  });

  test('Sin stock acepta cero o negativos, nunca stock desconocido', () {
    final result = InventoryStockFiltering.apply(
      products,
      InventoryStockFilter.empty,
    );
    expect(result.map((p) => p['codigo']), ['B', 'C']);
  });

  test('Filtrar no modifica la colección ni sus mapas', () {
    final result = InventoryStockFiltering.apply(
      products,
      InventoryStockFilter.empty,
    );
    expect(products, hasLength(5));
    expect(result, hasLength(2));
    expect(products.first['_totalStock'], 8);
  });
}
