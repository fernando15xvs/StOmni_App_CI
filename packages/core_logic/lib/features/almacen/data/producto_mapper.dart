import '../../catalogo/domain/catalog_item_type.dart';
import '../domain/product_unit_configuration.dart';
import '../domain/producto.dart';
import 'product_unit_configuration_mapper.dart';

class ProductoMapper {
  const ProductoMapper._();

  static Producto decode(Map<String, dynamic> json) {
    final configuration = ProductUnitConfigurationMapper.decodeNullable(
      json['unit_configuration'],
    );
    final unitLabel = json['unidad_medida']?.toString() ?? '';
    final legacyService = json['es_servicio'] == true ||
        json['es_servicio'] == 1 ||
        unitLabel.trim().toLowerCase() == 'servicios';
    final itemType = CatalogItemType.fromCode(
      json['item_type'],
      legacyService: legacyService,
    );
    final isInventoriable = itemType.isInventoriable;
    final invList = json['inventario_almacen'] as List<dynamic>? ?? [];
    final inventario = invList.map((raw) {
      if (raw is! Map) {
        throw const FormatException('El inventario del producto está dañado.');
      }
      final row = Map<String, dynamic>.from(raw);
      final rawWarehouseId = row['almacen_id'];
      if (rawWarehouseId is! num ||
          rawWarehouseId != rawWarehouseId.roundToDouble()) {
        throw const FormatException('El almacén del inventario es inválido.');
      }
      final stored = row['cantidad'] as num? ?? 0;
      final visible = !isInventoriable
          ? 0.0
          : configuration == null
              ? stored.toDouble()
              : configuration.fromStoredBaseQuantity(stored);
      return InventarioAlmacen(
        almacenId: rawWarehouseId.toInt(),
        cantidad: visible,
      );
    }).toList(growable: false);

    return Producto(
      id: (json['id'] as num).toInt(),
      codigo: json['codigo']?.toString(),
      nombre: json['nombre']?.toString() ?? '',
      codigoBarras: json['codigo_barras']?.toString(),
      descripcion: json['descripcion']?.toString(),
      precioUnidad: (json['precio_unidad'] as num?)?.toDouble() ?? 0.0,
      precioCaja: (json['precio_caja'] as num?)?.toDouble(),
      precioCompra: (json['precio_compra'] as num?)?.toDouble() ?? 0.0,
      unidadMedida: unitLabel,
      cantidadPorCaja: (json['cantidad_por_caja'] as num?)?.toInt(),
      tipoVenta: json['tipo_venta']?.toString(),
      categoria: json['categoria']?.toString(),
      proveedorId: (json['proveedor_id'] as num?)?.toInt(),
      permitirSinStock: json['permitir_sin_stock'] == true || !isInventoriable,
      itemType: itemType,
      imagenPath: json['imagen_path']?.toString(),
      pesoKg: (json['peso_kg'] as num?)?.toDouble() ?? 0,
      unidadGre: json['unidad_gre']?.toString() ?? 'NIU',
      stockMinimo: !isInventoriable
          ? 0
          : _visibleStockThreshold(json['stock_minimo'], configuration),
      inventario: inventario,
      unitConfiguration: configuration,
    );
  }

  static Map<String, dynamic> encode(Producto product) {
    final configuration = product.unitConfiguration;
    final isInventoriable = product.itemType.isInventoriable;
    return {
      'id': product.id,
      'codigo': product.codigo,
      'nombre': product.nombre,
      'codigo_barras': product.codigoBarras,
      'descripcion': product.descripcion,
      'precio_unidad': product.precioUnidad,
      'precio_caja': product.precioCaja,
      'precio_compra': product.precioCompra,
      'unidad_medida': product.esServicio ? 'Servicios' : product.unidadMedida,
      'cantidad_por_caja': product.cantidadPorCaja,
      'tipo_venta': product.tipoVenta,
      'categoria': product.categoria,
      'proveedor_id': product.proveedorId,
      'permitir_sin_stock': product.permitirSinStock || !isInventoriable,
      'es_servicio': product.esServicio,
      'item_type': product.itemType.code,
      'imagen_path': product.imagenPath,
      'peso_kg': product.pesoKg,
      'unidad_gre': product.unidadGre,
      'stock_minimo': !isInventoriable
          ? 0
          : configuration == null
              ? product.stockMinimo
              : configuration.toStoredBaseQuantity(product.stockMinimo),
      if (configuration != null)
        'unit_configuration': ProductUnitConfigurationMapper.encode(configuration),
      'inventario_almacen': product.inventario
          .map(
            (entry) => {
              'almacen_id': entry.almacenId,
              'cantidad': !isInventoriable
                  ? 0
                  : configuration == null
                      ? entry.cantidad
                      : configuration.toStoredBaseQuantity(entry.cantidad),
            },
          )
          .toList(growable: false),
    };
  }

  static double _visibleStockThreshold(
    Object? raw,
    ProductUnitConfiguration? configuration,
  ) {
    final stored = raw is num ? raw : num.tryParse(raw?.toString() ?? '') ?? 0;
    if (configuration == null) return stored.toDouble();
    return configuration.fromStoredBaseQuantity(stored);
  }
}