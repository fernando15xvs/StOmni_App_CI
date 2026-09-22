import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cotización conserva la validación estricta del total de línea', () {
    const line = SaleCartLine(
      productId: 1,
      warehouseId: 1,
      quantity: 100,
      subtotal: 100,
      commercialUnit: 'unidad',
      commercialUnitPrice: 1.01,
      baseUnitPrice: 1.01,
    );
    expect(
      () => SaleLinePersistenceMapper.map(line, requireExactTotals: true),
      throwsStateError,
    );
  });

  test('precio compartido conserva equivalencia, almacén y peso de GRE', () {
    final priced = const PriceSaleLineUseCase().execute(
      const SaleCartLine(
        productId: 7,
        warehouseId: 3,
        warehouseName: 'Central',
        quantity: 2,
        commercialUnit: 'caja',
        subtotal: 0,
        manualTotalWeightKg: 4.5,
        product: SaleProductSnapshot(
          code: 'A7',
          name: 'Producto',
          saleType: SaleUnitType.cajaUnidades,
          unitsPerPackage: 12,
          weightKg: 0.2,
          dispatchUnit: 'NIU',
          defaultUnitPrice: 10,
          defaultPackageBasePrice: 10,
        ),
      ),
      commercialUnitPrice: 120,
    );
    final roundtrip = SaleCartMapper.decode(
      SaleCartMapper.encode(SaleCart([priced])),
    ).lines.single;
    expect(roundtrip.subtotal, 240);
    expect(roundtrip.baseUnitPrice, 10);
    expect(roundtrip.recordedBaseQuantity, 24);
    expect(roundtrip.product.unitsPerPackage, 12);
    expect(roundtrip.warehouseName, 'Central');
    expect(roundtrip.product.weightKg, 0.2);
    expect(roundtrip.manualTotalWeightKg, 4.5);
    expect(roundtrip.product.dispatchUnit, 'NIU');
    final gre = GreItemMapper.desdeCarrito(
      SaleCartMapper.encode(SaleCart([roundtrip])),
    );
    expect(gre.single['peso_total_kg'], 4.5);
    expect(gre.single['producto_id'], 7);
  });

  test('la conversión histórica no retiene referencias mutables', () {
    final product = <String, dynamic>{
      'nombre': 'Original',
      'tipo_venta': 'UNIDAD',
      'cantidad_por_caja': 1,
    };
    final row = <String, dynamic>{
      'id': 1,
      'cantidad': 2,
      'subtotal': 20,
      'tipo_unidad': 'unidad',
      'producto_data': product,
    };
    final cart = SaleCartMapper.decode([row]);
    product['nombre'] = 'Mutado';
    row['subtotal'] = 999;
    expect(cart.lines.single.product.name, 'Original');
    expect(cart.totalAmount, 20);
    expect(() => cart.lines.clear(), throwsUnsupportedError);
    expect(() => cart.replaceProductLines(9, cart.lines), throwsArgumentError);
  });

  test('cola no descarta silenciosamente filas dañadas o versiones nuevas', () {
    expect(
      () => PendingSaleMapper.decode({'schema_version': 3}),
      throwsFormatException,
    );
    expect(
      () => PendingSaleMapper.decode({
        'detalles': [false],
      }),
      throwsFormatException,
    );
    expect(
      () => PendingSaleMapper.decode({
        'pagos': ['inválido'],
      }),
      throwsFormatException,
    );
    expect(() => SaleCartMapper.decodeLine({'id': 1.5}), throwsFormatException);
    expect(
      () => SaleCartMapper.decodeLine({'cantidad': double.nan}),
      throwsFormatException,
    );
  });

  test('cantidad base fraccionaria antigua no se trunca al validar', () {
    final line = SaleCartMapper.decodeLine({
      'id': 1,
      'almacen_id': 1,
      'cantidad': 2,
      'subtotal': 20,
      'tipo_unidad': 'unidad',
      'precio': 10,
      'precio_unitario': 10,
      'piezas_reales': 2.5,
    });
    expect(() => SaleLinePersistenceMapper.map(line), throwsStateError);
  });

  test('precio compartido no habilita inventario decimal por accidente', () {
    expect(
      () => const PriceSaleLineUseCase().execute(
        const SaleCartLine(
          productId: 1,
          warehouseId: 1,
          quantity: 1.5,
          commercialUnit: 'unidad',
          subtotal: 0,
        ),
        commercialUnitPrice: 10,
      ),
      throwsStateError,
    );
  });

  test('catálogo actual detecta equivalencia cambiada de una cotización', () {
    final line = SaleCartMapper.decodeLine({
      'id': 1,
      'almacen_id': 1,
      'cantidad': 1,
      'subtotal': 120,
      'tipo_unidad': 'caja',
      'precio': 120,
      'precio_unitario': 10,
      'piezas_reales': 12,
      'pcs_snapshot': 12,
      'tipo_venta_snapshot': 'CAJA_UNIDADES',
      'producto_data': {'tipo_venta': 'CAJA_UNIDADES', 'cantidad_por_caja': 24},
    });
    expect(() => SaleLinePersistenceMapper.map(line), throwsStateError);
  });
}
