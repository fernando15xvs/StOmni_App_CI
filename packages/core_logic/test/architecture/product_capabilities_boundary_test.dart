import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe $path');
  return file.readAsStringSync();
}

void main() {
  test(
    'ProductCapabilities es genérico y no depende de UI ni infraestructura',
    () {
      final source = _read(
        'lib/features/almacen/domain/product_capabilities.dart',
      );

      for (final forbidden in <String>[
        'package:flutter/',
        'flutter_riverpod',
        'BuildContext',
        'Supabase',
        'ferreter',
        'SaleUnitType',
      ]) {
        expect(source.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
      }

      expect(source, contains('class ProductCapabilities'));
      expect(source, contains('class ProductCapabilityPolicy'));
      expect(source, contains('productOverrides'));
      expect(source, contains('categoryOverrides'));
      expect(source, contains('allowedPresentationCodes'));
    },
  );

  test(
    'el catálogo puede resolver capacidades sin interpretar campos en UI',
    () {
      final source = _read(
        'lib/features/almacen/application/inventory_product_capabilities.dart',
      );

      expect(source, contains('extension InventoryCatalogItemCapabilities'));
      expect(source, contains('ProductCapabilities get legacyCapabilities'));
      expect(source, contains('ProductCapabilities capabilitiesFor('));
      expect(source, contains('canSellPresentation('));
    },
  );
}
