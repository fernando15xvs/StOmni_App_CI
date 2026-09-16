import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AlmacenSyncContract', () {
    test('ignora columnas remotas desconocidas antes de SQLite', () {
      final mapped = AlmacenSyncContract.productoParaCache({
        'id': 10,
        'nombre': 'Martillo',
        'codigo': 'M-10',
        'precio_unidad': 12.5,
        'inventario_almacen': [
          {'almacen_id': 1, 'cantidad': 4},
        ],
        'columna_nueva_que_sqlite_no_conoce': 'no debe pasar',
      });

      expect(mapped['id'], 10);
      expect(mapped['nombre'], 'Martillo');
      expect(mapped['codigo'], 'M-10');
      expect(mapped['inventario_almacen'], isA<List<dynamic>>());
      expect(mapped, isNot(contains('columna_nueva_que_sqlite_no_conoce')));
    });

    test('allowlist de almacenes y proveedores descarta extras', () {
      final almacen = AlmacenSyncContract.almacenParaCache({
        'id': 1,
        'nombre': 'Principal',
        'activo': true,
        'campo_futuro': 123,
      });
      final proveedor = AlmacenSyncContract.proveedorParaCache({
        'id': 2,
        'nombre': 'Proveedor',
        'ruc': '20123456789',
      });

      expect(almacen, containsPair('activo', true));
      expect(almacen, isNot(contains('campo_futuro')));
      expect(proveedor.keys, unorderedEquals(['id', 'nombre']));
    });

    test('1501 productos avanzan por cursor sin depender de offset', () {
      final primeraPagina = List<Map<String, dynamic>>.generate(
        AlmacenSyncContract.productPageSize,
        (index) => {'id': index + 1},
      );
      final segundaPagina = List<Map<String, dynamic>>.generate(
        501,
        (index) => {'id': 1001 + index},
      );

      expect(AlmacenSyncContract.hasMoreProducts(primeraPagina), isTrue);
      expect(AlmacenSyncContract.nextProductCursor(primeraPagina), 1000);
      expect(AlmacenSyncContract.hasMoreProducts(segundaPagina), isFalse);
      expect(AlmacenSyncContract.nextProductCursor(segundaPagina), 1501);
    });

    test('cursor falla cerrado si el lote no tiene id numérico', () {
      expect(
        () => AlmacenSyncContract.nextProductCursor([
          {'id': 'no-numerico'},
        ]),
        throwsFormatException,
      );
      expect(
        () => AlmacenSyncContract.nextProductCursor([]),
        throwsFormatException,
      );
    });

    test('select de productos usa esquema real explícito', () {
      expect(AlmacenSyncContract.productoSelect, isNot(contains('*')));
      expect(AlmacenSyncContract.productoSelect, contains('stock_minimo'));
      expect(
        AlmacenSyncContract.productoSelect,
        contains('inventario_almacen(almacen_id,cantidad)'),
      );

      // Estas columnas siguen existiendo nullable en SQLite por compatibilidad
      // histórica, pero no existen en el esquema remoto actual inspeccionado.
      expect(
        AlmacenSyncContract.productoSelect,
        isNot(contains('codigo_barras')),
      );
      expect(
        AlmacenSyncContract.productoSelect,
        isNot(contains('descripcion')),
      );
      expect(AlmacenSyncContract.productoSelect, isNot(contains('categoria')));
    });
  });
}
