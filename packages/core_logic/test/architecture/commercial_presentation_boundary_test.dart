import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe $path');
  return file.readAsStringSync();
}

void main() {
  test(
    'el modelo comercial genérico no depende del contrato legacy ni de UI',
    () {
      final source = _read(
        'lib/features/almacen/domain/commercial_presentation.dart',
      );

      for (final forbidden in <String>[
        'SaleUnitType',
        'StockUtils',
        'package:flutter/',
        'flutter_riverpod',
        'BuildContext',
        'Supabase',
      ]) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason:
              'El modelo comercial genérico volvió a depender de $forbidden',
        );
      }

      expect(source, contains('class CommercialPresentation'));
      expect(source, contains('class ProductUnitProfile'));
      expect(source, contains('allowsFractionalSale'));
      expect(source, contains('formatBaseQuantity'));
    },
  );

  test(
    'StockUtils funciona como adaptador del esquema comercial histórico',
    () {
      final source = _read('lib/utils/stock_utils.dart');

      expect(source, contains('static ProductUnitProfile legacyUnitProfile('));
      expect(source, contains('.formatBaseQuantity('));
      expect(source, contains('.toBaseQuantity('));
      expect(source, contains('.supports('));
    },
  );

  test(
    'el catálogo tipado expone el perfil comercial a cualquier interfaz',
    () {
      final source = _read(
        'lib/features/almacen/application/inventory_catalog_use_case.dart',
      );

      expect(source, contains('ProductUnitProfile get commercialProfile'));
      expect(source, contains('String get formattedStock'));
      expect(source, contains('StockUtils.legacyUnitProfile('));
    },
  );

  test('el resumen de carrito admite etiquetas configurables', () {
    final source = _read(
      'lib/features/ventas/application/sale_cart_summary.dart',
    );

    expect(
      source,
      contains('Map<String, CommercialPresentation> presentations'),
    );
    expect(source, contains('configured.format(quantity)'));
  });
}
