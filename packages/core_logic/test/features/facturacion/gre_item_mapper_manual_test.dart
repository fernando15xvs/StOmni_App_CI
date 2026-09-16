import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GreItemMapper.desdeCarrito', () {
    test('convierte caja a piezas y calcula peso desde catálogo', () {
      final result = GreItemMapper.desdeCarrito([
        {
          'cantidad': 2,
          'tipo_unidad': 'caja',
          'precio_unitario': 50,
          'producto_data': {
            'id': 7,
            'codigo': 'P-7',
            'nombre': 'Producto',
            'tipo_venta': 'CAJA_UNIDADES',
            'cantidad_por_caja': 4,
            'peso_kg': 0.5,
          },
        },
      ], almacenFallback: 3).single;

      expect(result['almacen_id'], 3);
      expect(result['unidad'], 'BX');
      expect(result['cantidad'], 2.0);
      expect(result['piezas_reales'], 8);
      expect(result['peso_unitario_kg'], 0.5);
      expect(result['peso_total_kg'], 4.0);
      expect(result['precio_unitario'], 50.0);
    });

    test('respeta peso específico manual como snapshot de la guía', () {
      final result = GreItemMapper.desdeCarrito([
        {
          'cantidad': 2,
          'tipo_unidad': 'unidad',
          'usar_peso_especifico': true,
          'peso_especifico_manual': 3.0,
          'producto_data': {
            'id': 9,
            'nombre': 'Pesado',
            'tipo_venta': 'UNIDAD',
            'cantidad_por_caja': 1,
            'peso_kg': 100,
          },
        },
      ]).single;

      expect(result['piezas_reales'], 2);
      expect(result['peso_total_kg'], 3.0);
      expect(result['peso_unitario_kg'], 1.5);
    });

    test('rechaza item sin snapshot de producto', () {
      expect(
        () => GreItemMapper.desdeCarrito([
          {'cantidad': 1},
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
