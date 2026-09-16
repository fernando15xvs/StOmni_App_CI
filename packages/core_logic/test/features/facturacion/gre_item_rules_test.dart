import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('GreItemRules', () {
    test('usa PK como unidad base para paquetes y caja+paquetes', () {
      expect(GreItemRules.unidadBaseProducto({'tipo_venta': 'PAQUETES'}), 'PK');
      expect(
        GreItemRules.unidadBaseProducto({'tipo_venta': 'CAJA_PAQUETES'}),
        'PK',
      );
    });

    test('corrige unidad_gre NIU cuando la base real es paquete', () {
      final producto = {'tipo_venta': 'CAJA_PAQUETES', 'unidad_gre': 'NIU'};

      expect(GreItemRules.unidadGreProducto(producto), 'PK');
    });

    test('caja+paquetes permite BX y PK', () {
      final producto = {'tipo_venta': 'CAJA_PAQUETES', 'cantidad_por_caja': 6};

      expect(GreItemRules.unidadesPermitidas(producto, 'PK'), ['BX', 'PK']);
    });

    test('caja+unidades permite BX y NIU', () {
      final producto = {'tipo_venta': 'CAJA_UNIDADES', 'cantidad_por_caja': 12};

      expect(GreItemRules.unidadesPermitidas(producto, 'NIU'), ['BX', 'NIU']);
    });

    test('conserva una unidad histórica actualmente seleccionada', () {
      final producto = {'tipo_venta': 'CAJA_UNIDADES', 'cantidad_por_caja': 12};

      expect(GreItemRules.unidadesPermitidas(producto, 'ZZ'), [
        'BX',
        'NIU',
        'ZZ',
      ]);
    });

    test('convierte cajas a unidades base según PCS', () {
      final producto = {'tipo_venta': 'CAJA_UNIDADES', 'cantidad_por_caja': 12};

      final piezas = GreItemRules.calcularPiezasDetalle(
        producto: producto,
        unidadSunat: 'BX',
        cantidadVisual: 2,
      );

      expect(piezas, 24);
    });

    test('convierte cajas a paquetes base según PCS', () {
      final producto = {'tipo_venta': 'CAJA_PAQUETES', 'cantidad_por_caja': 6};

      final piezas = GreItemRules.calcularPiezasDetalle(
        producto: producto,
        unidadSunat: 'BX',
        cantidadVisual: 2,
      );

      expect(piezas, 12);
    });

    test('rechaza cantidades fraccionarias en unidades comerciales', () {
      expect(
        () => GreItemRules.calcularPiezasDetalle(
          producto: {'tipo_venta': 'CAJA_UNIDADES', 'cantidad_por_caja': 12},
          unidadSunat: 'NIU',
          cantidadVisual: 1.5,
        ),
        throwsFormatException,
      );
    });

    test('ZZ conserva piezas reales explícitas', () {
      final piezas = GreItemRules.calcularPiezasDetalle(
        producto: null,
        unidadSunat: 'ZZ',
        cantidadVisual: 3,
        piezasFallback: 17,
      );

      expect(piezas, 17);
    });

    test('rechaza una presentación no permitida por el producto', () {
      expect(
        () => GreItemRules.calcularPiezasDetalle(
          producto: {'tipo_venta': 'PAQUETES', 'cantidad_por_caja': 4},
          unidadSunat: 'NIU',
          cantidadVisual: 2,
        ),
        throwsArgumentError,
      );
    });
  });
}
