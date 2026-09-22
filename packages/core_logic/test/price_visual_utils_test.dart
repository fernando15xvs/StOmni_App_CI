import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PriceVisualUtils canonical contract', () {
    test('commercial line price prioritizes subtotal over catalog price', () {
      expect(
        PriceVisualUtils.getPrecioComercialLinea(
          precioUnitarioBase: 4,
          subtotal: 48,
          cantidadVisual: 2,
          pcs: 12,
          tipoVentaProducto: 'CAJA_UNIDADES',
          tipoUnidad: 'caja',
        ),
        24,
      );
    });

    test('closed-box price uses the canonical box factor', () {
      expect(
        PriceVisualUtils.getPrecioComercialLinea(
          precioUnitarioBase: 2,
          cantidadVisual: 1,
          pcs: 10,
          tipoVentaProducto: 'CAJA_UNIDADES',
          tipoUnidad: 'caja',
        ),
        20,
      );
    });

    test('obsolete sale type alias fails fast', () {
      expect(
        () => PriceVisualUtils.getPrecioComercialLinea(
          precioUnitarioBase: 2,
          cantidadVisual: 1,
          pcs: 10,
          tipoVentaProducto: 'AMBOS',
          tipoUnidad: 'caja',
        ),
        throwsFormatException,
      );
    });
  });
}
