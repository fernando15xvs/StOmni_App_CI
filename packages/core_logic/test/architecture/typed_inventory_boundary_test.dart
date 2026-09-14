import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Phase 4 typed inventory boundaries', () {
    test('inventory catalog gateway and snapshot are typed', () {
      final source = _read(
        'lib/features/almacen/application/inventory_catalog_use_case.dart',
      );

      expect(source, contains('class InventoryCatalogItem'));
      expect(source, contains('class InventoryWarehouseRecord'));
      expect(
        source,
        contains('Future<List<InventoryWarehouseRecord>> loadWarehouses()'),
      );
      expect(source, contains('Future<List<Producto>> loadInactiveProducts()'));
      expect(source, contains('final List<InventoryCatalogItem> products;'));
      expect(
        source,
        contains('final List<InventoryWarehouseRecord> warehouses;'),
      );
      expect(
        source,
        isNot(contains('Future<List<Map<String, dynamic>>> loadWarehouses()')),
      );
      expect(
        source,
        isNot(contains('final List<Map<String, dynamic>> products;')),
      );
    });

    test('stock movement gateway returns a typed result', () {
      final source = _read(
        'lib/features/almacen/application/register_stock_movement_use_case.dart',
      );

      expect(source, contains('Future<StockMovementResult> register('));
      expect(
        source,
        isNot(contains('Future<Map<String, dynamic>> register(')),
      );
    });

    test('product lifecycle evaluation is typed', () {
      final source = _read(
        'lib/features/almacen/application/product_lifecycle_use_case.dart',
      );

      expect(source, contains('class ProductDeletionEvaluation'));
      expect(
        source,
        contains('Future<ProductDeletionEvaluation> evaluateDeletion('),
      );
      expect(
        source,
        isNot(contains('Future<Map<String, dynamic>> evaluateDeletion(')),
      );
    });

    test('merchandise entry command uses typed allocations', () {
      final source = _read(
        'lib/features/almacen/application/register_merchandise_entry_use_case.dart',
      );

      expect(source, contains('class MerchandiseWarehouseAllocation'));
      expect(
        source,
        contains('final List<MerchandiseWarehouseAllocation> warehouses;'),
      );
      expect(
        source,
        isNot(contains('final List<Map<String, dynamic>> warehouses;')),
      );
    });

    test('warehouse administration exposes typed records', () {
      final source = _read(
        'lib/features/almacen/application/warehouse_admin_use_case.dart',
      );

      expect(source, contains('class WarehouseAdminRecord'));
      expect(
        source,
        contains('Future<List<WarehouseAdminRecord>> listWarehouses()'),
      );
      expect(
        source,
        isNot(contains('Future<List<Map<String, dynamic>>> listWarehouses()')),
      );
    });
  });
}
