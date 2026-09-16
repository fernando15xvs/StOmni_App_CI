import '../../../utils/stock_utils.dart';
import '../../almacen/data/product_unit_configuration_mapper.dart';
import '../domain/sale_cart.dart';
import '../domain/sale_product_snapshot.dart';

/// Única traducción entre el carrito tipado y snapshots históricos de SQLite,
/// cotizaciones o catálogo. Escribe las claves antiguas para no romper la cola.
class SaleCartMapper {
  const SaleCartMapper._();

  static SaleCart decode(Iterable<Map<String, dynamic>> rows) =>
      SaleCart(rows.map(decodeLine));

  static SaleProductSnapshot decodeProduct(Map<String, dynamic> row) =>
      SaleProductSnapshot(
        unitConfiguration: ProductUnitConfigurationMapper.decodeNullable(
          row['unit_configuration'],
        ),
        code: row['codigo']?.toString() ?? '',
        name: row['nombre']?.toString() ?? 'Producto',
        saleType: StockUtils.getTipoVentaFromMap(row),
        unitsPerPackage: _integer(row['cantidad_por_caja'], fallback: 1),
        defaultUnitPrice: _number(row['precio_unidad']),
        defaultPackageBasePrice: _number(row['precio_caja']),
        weightKg: _number(row['peso_kg']),
        dispatchUnit: row['unidad_gre']?.toString() ?? '',
      );

  static SaleCartLine decodeLine(Map<String, dynamic> row) {
    final rawProduct = row['producto_data'] ?? row['productos'];
    final product = <String, dynamic>{
      'codigo': row['codigo'],
      'nombre': row['nombre'],
      'tipo_venta': row['tipo_venta_snapshot'],
      'cantidad_por_caja': row['pcs_snapshot'],
      if (rawProduct is Map) ...Map<String, dynamic>.from(rawProduct),
    };
    final snapshot = decodeProduct(product);
    final rawSerials = row['serial_numbers'];
    final serials = rawSerials is List
        ? rawSerials.map((value) => value.toString()).toList(growable: false)
        : const <String>[];
    return SaleCartLine(
      productId: _integer(row['id'] ?? row['producto_id']),
      warehouseId: _integer(row['almacen_id']),
      warehouseName: row['almacen_nombre']?.toString() ?? '',
      quantity: _number(row['cantidad']),
      subtotal: _number(row['subtotal']),
      commercialUnit: snapshot.normalizeUnit(
        row['tipo_unidad']?.toString() ??
            snapshot.commercialProfile.baseUnit.code,
      ),
      product: snapshot,
      commercialUnitPrice: _number(
        row['precio_unitario_comercial'] ?? row['precio'],
      ),
      baseUnitPrice: _number(row['precio_unitario']),
      recordedBaseQuantity: row['piezas_reales'] == null
          ? null
          : _number(row['piezas_reales']),
      manualTotalWeightKg:
          row['usar_peso_especifico'] == true &&
              row['peso_especifico_manual'] != null
          ? _number(row['peso_especifico_manual'])
          : null,
      serialNumbers: List<String>.unmodifiable(serials),
    );
  }

  static List<Map<String, dynamic>> encode(SaleCart cart) =>
      cart.lines.map(encodeLine).toList(growable: false);

  static Map<String, dynamic> encodeLine(SaleCartLine line) => {
    'id': line.productId,
    'codigo': line.product.code,
    'nombre': line.product.name,
    'almacen_id': line.warehouseId,
    'almacen_nombre': line.warehouseName,
    'cantidad': line.quantity,
    'subtotal': line.subtotal,
    'tipo_unidad': line.commercialUnit,
    'precio': line.commercialUnitPrice,
    'precio_unitario_comercial': line.commercialUnitPrice,
    'precio_unitario': line.baseUnitPrice,
    if (line.recordedBaseQuantity != null)
      'piezas_reales': line.recordedBaseQuantity,
    if (line.serialNumbers.isNotEmpty)
      'serial_numbers': List<String>.unmodifiable(line.serialNumbers),
    'tipo_venta_snapshot': StockUtils.toDatabaseValue(line.product.saleType),
    'pcs_snapshot': line.product.unitsPerPackage,
    'unidad_base_snapshot':
        line.product.commercialProfile.baseUnit.singularLabel,
    if (line.manualTotalWeightKg != null) ...{
      'usar_peso_especifico': true,
      'peso_especifico_manual': line.manualTotalWeightKg,
    },
    'producto_data': {
      'id': line.productId,
      'codigo': line.product.code,
      'nombre': line.product.name,
      'tipo_venta': StockUtils.toDatabaseValue(line.product.saleType),
      'cantidad_por_caja': line.product.unitsPerPackage,
      'precio_unidad': line.product.defaultUnitPrice,
      'precio_caja': line.product.defaultPackageBasePrice,
      'peso_kg': line.product.weightKg,
      'unidad_gre': line.product.dispatchUnit,
      if (line.product.unitConfiguration != null)
        'unit_configuration': ProductUnitConfigurationMapper.encode(
          line.product.unitConfiguration!,
        ),
    },
  };

  static double _number(Object? value) {
    if (value == null) return 0;
    final result = value is num
        ? value.toDouble()
        : double.tryParse(value.toString());
    if (result == null || !result.isFinite) {
      throw const FormatException('El snapshot contiene un número inválido.');
    }
    return result;
  }

  static int _integer(Object? value, {int fallback = 0}) {
    if (value == null) return fallback;
    final result = _number(value);
    if (result != result.roundToDouble()) {
      throw const FormatException(
        'El snapshot contiene un identificador o factor fraccionario.',
      );
    }
    return result.toInt();
  }
}
