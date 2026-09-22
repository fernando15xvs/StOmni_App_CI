import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SaleLinePersistenceMapper', () {
    test('prepara una venta por caja con equivalencia de unidades', () {
      final line = SaleCartMapper.decodeLine({
        'id': 10,
        'cantidad': 2,
        'subtotal': 240.0,
        'tipo_unidad': 'caja',
        'almacen_id': 3,
        'precio': 120.0,
        'precio_unitario_comercial': 120.0,
        'precio_unitario': 10.0,
        'piezas_reales': 24,
        'producto_data': {
          'nombre': 'Producto mixto',
          'tipo_venta': 'CAJA_UNIDADES',
          'cantidad_por_caja': 12,
        },
      });

      final prepared = SaleLinePersistenceMapper.map(line);

      expect(prepared, isA<SaleProcessingLine>());
      expect(prepared.productId, 10);
      expect(prepared.warehouseId, 3);
      expect(prepared.quantity, 2);
      expect(prepared.baseQuantity, 24);
      expect(prepared.unitCode, 'caja');
      expect(prepared.baseUnitLabel, 'Unidad');
      expect(prepared.commercialUnitPrice, 120);
      expect(prepared.baseUnitPrice, 10);
      expect(prepared.subtotal, 240);
    });

    test('prepara una venta por unidad del mismo producto', () {
      final line = SaleCartMapper.decodeLine({
        'id': 10,
        'cantidad': 3,
        'subtotal': 30.0,
        'tipo_unidad': 'unidad',
        'almacen_id': 3,
        'precio': 10.0,
        'precio_unitario_comercial': 10.0,
        'precio_unitario': 10.0,
        'piezas_reales': 3,
        'producto_data': {
          'nombre': 'Producto mixto',
          'tipo_venta': 'CAJA_UNIDADES',
          'cantidad_por_caja': 12,
        },
      });

      final prepared = SaleLinePersistenceMapper.map(line);

      expect(prepared.quantity, 3);
      expect(prepared.baseQuantity, 3);
      expect(prepared.unitCode, 'unidad');
      expect(prepared.commercialUnitPrice, 10);
      expect(prepared.baseUnitPrice, 10);
    });

    test('rechaza cantidad fraccionaria mientras el inventario sea sin perfil configurable', () {
      final line = SaleCartMapper.decodeLine({
        'id': 20,
        'cantidad': 1.5,
        'subtotal': 15.0,
        'tipo_unidad': 'kg',
        'almacen_id': 1,
        'precio': 10.0,
        'precio_unitario': 10.0,
        'producto_data': {
          'nombre': 'Producto por peso',
          'tipo_venta': 'UNIDAD',
          'cantidad_por_caja': 1,
        },
      });

      expect(
        () => SaleLinePersistenceMapper.map(line),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('cantidad fraccionaria'),
          ),
        ),
      );
    });

    test('rechaza precios inconsistentes antes de persistir', () {
      final line = SaleCartMapper.decodeLine({
        'id': 30,
        'cantidad': 2,
        'subtotal': 20.0,
        'tipo_unidad': 'unidad',
        'almacen_id': 1,
        'precio': 15.0,
        'precio_unitario_comercial': 15.0,
        'precio_unitario': 10.0,
        'producto_data': {
          'nombre': 'Producto',
          'tipo_venta': 'UNIDAD',
          'cantidad_por_caja': 1,
        },
      });

      expect(
        () => SaleLinePersistenceMapper.map(line),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no son consistentes'),
          ),
        ),
      );
    });
  });
}
