import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SaleCart', () {
    test('calcula total y líneas desde payload serializado', () {
      final cart = SaleCartMapper.decode([
        {
          'id': 10,
          'cantidad': 2,
          'subtotal': 30.0,
          'tipo_unidad': 'caja',
          'producto_data': {
            'tipo_venta': 'CAJA_UNIDADES',
            'cantidad_por_caja': 12,
          },
        },
        {
          'id': 11,
          'cantidad': 3,
          'subtotal': 7.5,
          'tipo_unidad': 'unidad',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
      ]);

      expect(cart.lineCount, 2);
      expect(cart.totalAmount, 37.5);
      expect(cart.containsProduct(10), isTrue);
      expect(cart.containsProduct(99), isFalse);
    });

    test('agrega cantidades por presentación comercial', () {
      final cart = SaleCartMapper.decode([
        {
          'id': 1,
          'cantidad': 2,
          'subtotal': 10,
          'tipo_unidad': 'CAJAS',
          'producto_data': {
            'tipo_venta': 'CAJA_UNIDADES',
            'cantidad_por_caja': 12,
          },
        },
        {
          'id': 2,
          'cantidad': 3,
          'subtotal': 15,
          'tipo_unidad': 'caja',
          'producto_data': {
            'tipo_venta': 'CAJA_UNIDADES',
            'cantidad_por_caja': 12,
          },
        },
        {
          'id': 3,
          'cantidad': 4,
          'subtotal': 8,
          'tipo_unidad': 'paq',
          'producto_data': {
            'tipo_venta': 'PAQUETE',
            'cantidad_por_caja': 1,
          },
        },
      ]);

      expect(cart.quantityFor('caja'), 5);
      expect(cart.quantityFor('paquete'), 4);
    });

    test('conserva presentaciones futuras no conocidas', () {
      final cart = SaleCartMapper.decode([
        {
          'id': 1,
          'cantidad': 5,
          'subtotal': 25,
          'tipo_unidad': 'kg',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
        {
          'id': 2,
          'cantidad': 12,
          'subtotal': 36,
          'tipo_unidad': 'metro',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
      ]);

      expect(cart.quantityFor('kg'), 5);
      expect(cart.quantityFor('metro'), 12);
      expect(cart.quantitiesByUnit.keys, containsAll(['kg', 'metro']));
    });

    test('acepta cantidades fraccionarias para peso o longitud', () {
      final cart = SaleCartMapper.decode([
        {
          'id': 20,
          'cantidad': 1.5,
          'subtotal': 12.75,
          'tipo_unidad': 'kg',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
        {
          'id': 21,
          'cantidad': 2.25,
          'subtotal': 18,
          'tipo_unidad': 'metro',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
      ]);

      expect(cart.quantityFor('kg'), 1.5);
      expect(cart.quantityFor('metro'), 2.25);
      expect(cart.totalAmount, 30.75);
    });

    test('reemplaza todas las líneas comerciales de un producto', () {
      final original = SaleCartMapper.decode([
        {
          'id': 7,
          'cantidad': 1,
          'subtotal': 10,
          'tipo_unidad': 'caja',
          'producto_data': {
            'tipo_venta': 'CAJA_UNIDADES',
            'cantidad_por_caja': 12,
          },
        },
        {
          'id': 8,
          'cantidad': 2,
          'subtotal': 4,
          'tipo_unidad': 'unidad',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
      ]);

      final updated = original.replaceProductLines(
        7,
        SaleCartMapper.decode([
          {
            'id': 7,
            'cantidad': 6,
            'subtotal': 18,
            'tipo_unidad': 'unidad',
            'producto_data': {
              'tipo_venta': 'CAJA_UNIDADES',
              'cantidad_por_caja': 12,
            },
          },
        ]).lines,
      );

      expect(updated.lineCount, 2);
      expect(updated.quantityFor('caja'), 0);
      expect(updated.quantityFor('unidad'), 8);
      expect(updated.totalAmount, 22);
    });

    test('elimina un producto y conserva payload serializado', () {
      final originalPayload = <String, dynamic>{
        'id': 5,
        'cantidad': 2,
        'subtotal': 9.5,
        'tipo_unidad': 'unidad',
        'nombre': 'Producto de prueba',
        'producto_data': {
          'nombre': 'Producto de prueba',
          'tipo_venta': 'UNIDAD',
          'cantidad_por_caja': 1,
        },
      };
      final cart = SaleCartMapper.decode([
        originalPayload,
        {
          'id': 6,
          'cantidad': 1,
          'subtotal': 4,
          'tipo_unidad': 'unidad',
          'producto_data': {'tipo_venta': 'UNIDAD', 'cantidad_por_caja': 1},
        },
      ]);

      expect(cart.lines.first.product.name, 'Producto de prueba');

      final remaining = cart.removeProduct(5);
      expect(remaining.lineCount, 1);
      expect(remaining.containsProduct(5), isFalse);
      expect(remaining.containsProduct(6), isTrue);
    });
  });
}
