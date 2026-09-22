import 'dart:convert';

import '../../catalogo/domain/catalog_item_type.dart';
import '../../../utils/stock_utils.dart';

class ProductoBusqueda {
  final int id;
  final String? codigo;
  final String nombre;
  final String? codigoBarras;
  final String? proveedorNombre;
  final String tipoVenta;
  final int cantidadPorCaja;
  final CatalogItemType itemType;
  final List<dynamic> inventarioAlmacenes;
  final bool activo;
  final Map<String, dynamic> rawData;

  bool get esInventariable => itemType.isInventoriable;
  bool get esServicio => itemType.isService;
  bool get esBundle => itemType.isBundle;

  ProductoBusqueda({
    required this.id,
    this.codigo,
    required this.nombre,
    this.codigoBarras,
    this.proveedorNombre,
    required this.tipoVenta,
    required this.cantidadPorCaja,
    this.itemType = CatalogItemType.stockProduct,
    required this.inventarioAlmacenes,
    required this.activo,
    required this.rawData,
  });

  factory ProductoBusqueda.fromMap(Map<String, dynamic> map) {
    List<dynamic> inventario = [];
    if (map['inventario_almacen'] != null) {
      if (map['inventario_almacen'] is String) {
        try {
          inventario = jsonDecode(map['inventario_almacen']) as List<dynamic>;
        } catch (_) {
          inventario = [];
        }
      } else if (map['inventario_almacen'] is List) {
        inventario = List<dynamic>.from(map['inventario_almacen'] as List);
      }
    }

    String? provNombre = map['proveedor_nombre']?.toString();
    if (provNombre == null && map['proveedores'] is Map) {
      provNombre = (map['proveedores'] as Map)['nombre']?.toString();
    }
    final legacyService =
        map['es_servicio'] == true ||
        map['es_servicio'] == 1 ||
        map['unidad_medida']?.toString().trim().toLowerCase() == 'servicios';
    final itemType = CatalogItemType.fromCode(
      map['item_type'],
      legacyService: legacyService,
    );

    final rawSaleType = map['tipo_venta']?.toString().trim() ?? '';
    if (rawSaleType.isEmpty) {
      throw const FormatException('Producto sin tipo_venta canónico.');
    }
    final saleType = rawSaleType;
    StockUtils.getTipoVentaFromString(saleType);

    return ProductoBusqueda(
      id: (map['id'] as num).toInt(),
      codigo: map['codigo']?.toString(),
      nombre: map['nombre']?.toString() ?? 'Sin Nombre',
      codigoBarras: map['codigo_barras']?.toString(),
      proveedorNombre: provNombre,
      tipoVenta: saleType,
      cantidadPorCaja: (map['cantidad_por_caja'] as num?)?.toInt() ?? 1,
      itemType: itemType,
      inventarioAlmacenes: itemType.isInventoriable ? inventario : const [],
      activo: map['activo'] == 1 || map['activo'] == true,
      rawData: Map<String, dynamic>.from(map),
    );
  }

  Map<String, dynamic> toMap() {
    final map = Map<String, dynamic>.from(rawData);
    map['codigo'] = codigo;
    map['item_type'] = itemType.code;
    map['es_servicio'] = itemType.isService;
    map['inventario_almacen'] = itemType.isInventoriable
        ? inventarioAlmacenes
        : const <dynamic>[];
    if (proveedorNombre != null && map['proveedores'] == null) {
      map['proveedores'] = {'nombre': proveedorNombre};
    }
    return map;
  }
}
