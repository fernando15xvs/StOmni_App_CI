import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('GreItemMapper', () {
    test('mapea detalle de venta conservando snapshot y peso', () {
      final producto = <String, dynamic>{
        'id': 7,
        'codigo': 'P-007',
        'nombre': 'Tornillo',
        'tipo_venta': 'CAJA_UNIDADES',
        'cantidad_por_caja': 10,
        'peso_kg': 0.25,
      };
      final item = <String, dynamic>{
        'id': 99,
        'producto_id': 7,
        'almacen_id': 3,
        'tipo_unidad': 'caja',
        'cantidad': 2,
        'piezas_reales': 20,
        'pcs_snapshot': 10,
      };

      final result = GreItemMapper.desdeVenta(item, producto);

      expect(result['producto_id'], 7);
      expect(result['detalle_venta_id'], 99);
      expect(result['almacen_id'], 3);
      expect(result['unidad'], 'BX');
      expect(result['cantidad'], 2.0);
      expect(result['piezas_reales'], 20);
      expect(result['peso_unitario_kg'], 0.25);
      expect(result['peso_total_kg'], 5.0);
      expect(result['descripcion'], 'Tornillo - Caja x 10');
      expect(result['producto_data'], same(producto));
    });

    test('mapea venta por paquete como PK', () {
      final result = GreItemMapper.desdeVenta(
        {
          'id': 1,
          'producto_id': 2,
          'almacen_id': 1,
          'tipo_unidad': 'paquete',
          'cantidad': 3,
          'piezas_reales': 3,
        },
        {
          'id': 2,
          'codigo': 'PK-2',
          'nombre': 'Tarugos',
          'tipo_venta': 'PAQUETES',
          'cantidad_por_caja': 20,
          'peso_kg': 0.4,
        },
      );

      expect(result['unidad'], 'PK');
      expect(result['descripcion'], 'Tarugos - Paquete');
      expect(result['peso_total_kg'], closeTo(1.2, 0.000001));
    });

    test('usa el snapshot configurable sin alterar piezas ni peso', () {
      final result = GreItemMapper.desdeVenta(
        {
          'id': 3,
          'producto_id': 9,
          'almacen_id': 1,
          'cantidad': 12,
          'piezas_reales': 12,
          'presentation_snapshot': {
            'quantity': 2,
            'singular': 'Pack',
            'factor': 6,
            'base_quantity': 12,
            'profile': {
              'base_code': 'unidad',
              'presentations': [
                {
                  'code': 'unidad',
                  'singular': 'Unidad',
                  'plural': 'Unidades',
                  'factor': 1,
                  'fiscal_unit_code': 'NIU',
                },
                {
                  'code': 'pack_6',
                  'singular': 'Pack',
                  'plural': 'Packs',
                  'factor': 6,
                  'fiscal_unit_code': 'NIU',
                },
              ],
            },
          },
        },
        {
          'id': 9,
          'nombre': 'Agua',
          'tipo_venta': 'CAJA_UNIDADES',
          'unidad_gre': 'NIU',
          'peso_kg': 0.5,
        },
      );
      expect(result['unidad'], 'NIU');
      expect(result['cantidad'], 12.0);
      expect(result['piezas_reales'], 12);
      expect(result['peso_total_kg'], 6.0);
      expect(result['descripcion'], 'Agua - Pack x 6');
    });

    test('mapea traslado usando unidad GRE base del producto', () {
      final result = GreItemMapper.desdeTraslado(
        {'id': 15, 'producto_id': 4, 'almacen_origen_id': 2, 'cantidad': 8},
        {
          'id': 4,
          'codigo': 'A-4',
          'nombre': 'Abrazadera',
          'tipo_venta': 'CAJA_PAQUETES',
          'cantidad_por_caja': 6,
          'unidad_gre': 'NIU',
          'peso_kg': 0.5,
        },
      );

      expect(result['transferencia_id'], 15);
      expect(result['almacen_id'], 2);
      expect(result['unidad'], 'PK');
      expect(result['cantidad'], 8.0);
      expect(result['piezas_reales'], 8);
      expect(result['peso_total_kg'], 4.0);
      expect(result['descripcion'], 'Abrazadera');
    });

    test('descripcion usa PCS snapshot antes que catálogo actual', () {
      final descripcion = GreItemMapper.descripcionPresentacion(
        {'tipo_unidad': 'caja', 'pcs_snapshot': 4},
        {'nombre': 'Producto', 'cantidad_por_caja': 20},
      );

      expect(descripcion, 'Producto - Caja x 4');
    });
  });
}
