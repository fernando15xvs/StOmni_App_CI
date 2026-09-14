class AlmacenSyncContract {
  AlmacenSyncContract._();

  static const int productPageSize = 1000;

  // Debe reflejar únicamente columnas reales de public.productos que el caché
  // local consume. item_type es autoritativo desde F5.2; es_servicio continúa
  // durante la transición para compatibilidad con clientes previos.
  static const String productoSelect =
      'id,nombre,precio_unidad,precio_caja,precio_compra,imagen_path,'
      'unidad_medida,proveedor_id,permitir_sin_stock,es_servicio,item_type,cantidad_por_caja,'
      'created_at,tipo_venta,activo,codigo,peso_kg,unidad_gre,stock_minimo,'
      'inventario_almacen(almacen_id,cantidad)';

  static const String almacenSelect =
      'id,nombre,direccion,activo,ubigeo,departamento,provincia,distrito,'
      'cod_local,referencia,updated_at';

  static const String proveedorSelect = 'id,nombre';

  static const Set<String> _productoCacheColumns = {
    'id',
    'codigo',
    'nombre',
    'codigo_barras',
    'descripcion',
    'precio_unidad',
    'precio_caja',
    'precio_compra',
    'unidad_medida',
    'cantidad_por_caja',
    'tipo_venta',
    'categoria',
    'proveedor_id',
    'permitir_sin_stock',
    'imagen_path',
    'peso_kg',
    'unidad_gre',
    'inventario_almacen',
    'created_at',
    'activo',
    'stock_minimo',
    'unit_configuration',
    'item_type',
    'es_servicio',
  };

  static const Set<String> _almacenCacheColumns = {
    'id',
    'nombre',
    'direccion',
    'ubigeo',
    'departamento',
    'provincia',
    'distrito',
    'cod_local',
    'referencia',
    'updated_at',
    'activo',
  };

  static const Set<String> _proveedorCacheColumns = {'id', 'nombre'};

  static Map<String, dynamic> productoParaCache(Map<String, dynamic> remoto) {
    return _allowlist(remoto, _productoCacheColumns);
  }

  static Map<String, dynamic> almacenParaCache(Map<String, dynamic> remoto) {
    return _allowlist(remoto, _almacenCacheColumns);
  }

  static Map<String, dynamic> proveedorParaCache(Map<String, dynamic> remoto) {
    return _allowlist(remoto, _proveedorCacheColumns);
  }

  static int nextProductCursor(List<Map<String, dynamic>> batch) {
    if (batch.isEmpty) {
      throw const FormatException('No se puede calcular cursor de un lote vacío.');
    }

    final rawId = batch.last['id'];
    if (rawId is! num) {
      throw const FormatException('Producto remoto sin id numérico válido.');
    }
    return rawId.toInt();
  }

  static bool hasMoreProducts(List<Map<String, dynamic>> batch) {
    return batch.length == productPageSize;
  }

  static Map<String, dynamic> _allowlist(
    Map<String, dynamic> source,
    Set<String> allowed,
  ) {
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      if (allowed.contains(entry.key)) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}