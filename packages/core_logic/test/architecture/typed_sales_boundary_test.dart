import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Phase 4 typed sales boundaries', () {
    test('carrito, cola y comandos no esconden mapas dinámicos', () {
      for (final path in [
        'domain/sale_cart.dart',
        'domain/sale_product_snapshot.dart',
        'domain/sale_models.dart',
        'application/procesar_venta_command.dart',
        'application/venta_submission_coordinator.dart',
        'application/legacy_sale_line_mapper.dart',
        'application/price_sale_line_use_case.dart',
        'usecases/procesar_venta_usecase.dart',
      ]) {
        final source = _read('lib/features/ventas/$path');
        expect(source, isNot(contains('Map<String, dynamic>')), reason: path);
        expect(source, isNot(contains('legacyPayload')), reason: path);
        expect(source, isNot(contains('../data/')), reason: path);
      }
    });

    test('processing port does not expose persistence maps', () {
      final source = _read(
        'lib/features/ventas/application/venta_application_ports.dart',
      );

      expect(source, contains('Future<VentaProcessingResult> processSale('));
      expect(source, contains('VentaProcessingRequest request'));
      expect(source, isNot(contains('Future<Map<String, dynamic>> processSale')));
      expect(source, isNot(contains('List<Map<String, dynamic>> detalles')));
      expect(source, isNot(contains('List<Map<String, dynamic>> pagos')));
    });

    test('processing command does not expose legacy payload getters', () {
      final source = _read(
        'lib/features/ventas/application/procesar_venta_command.dart',
      );

      expect(source, isNot(contains('pagosLegacy')));
      expect(source, isNot(contains('carritoLegacy')));
    });

    test('application mapper returns typed lines without serializing RPC maps', () {
      final source = _read(
        'lib/features/ventas/application/legacy_sale_line_mapper.dart',
      );

      expect(source, contains('static SaleProcessingLine map('));
      expect(source, isNot(contains('toPersistenceMap')));
    });

    test('submission coordinator consumes typed processing results', () {
      final source = _read(
        'lib/features/ventas/application/venta_submission_coordinator.dart',
      );

      expect(source, contains('final VentaProcessingResult? result;'));
      expect(source, contains('resultado.idempotent'));
      expect(source, contains('resultado.comprobanteId'));
      expect(source, isNot(contains("resultado['idempotent']")));
      expect(source, isNot(contains("resultado['comprobante_id']")));
    });
  });
}
