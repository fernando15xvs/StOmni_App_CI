import '../../../utils/stock_utils.dart';
import 'gre_item_rules.dart';

/// Convierte fuentes ya cargadas al snapshot de detalle que usa el formulario
/// GRE. No consulta base de datos ni modifica inventario.
class GreItemMapper {
  const GreItemMapper._();

  static bool esServicio(Map<String, dynamic> producto) {
    return producto['es_servicio'] == true ||
        producto['es_servicio'] == 1 ||
        producto['unidad_medida']?.toString().trim().toLowerCase() ==
            'servicios';
  }

  static Map<String, dynamic>? _snapshot(Map<String, dynamic> item) {
    final raw = item['presentation_snapshot'];
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  static String? _baseFiscalUnit(Map<String, dynamic> snapshot) {
    final profileRaw = snapshot['profile'];
    if (profileRaw is! Map) return null;
    final profile = Map<String, dynamic>.from(profileRaw);
    final baseCode = profile['base_code']?.toString();
    final presentations = profile['presentations'];
    if (baseCode == null || presentations is! List) return null;
    for (final raw in presentations) {
      if (raw is! Map || raw['code']?.toString() != baseCode) continue;
      final fiscal = raw['fiscal_unit_code']?.toString().trim().toUpperCase();
      if (fiscal != null && RegExp(r'^[A-Z0-9]{1,6}$').hasMatch(fiscal)) {
        return fiscal;
      }
    }
    return null;
  }

  static String _requiredBaseFiscalUnit(
    Map<String, dynamic> snapshot,
    String productName,
  ) {
    final unit = _baseFiscalUnit(snapshot);
    if (unit == null) {
      throw FormatException(
        'La unidad base de $productName no tiene código fiscal para la GRE. '
        'Configúralo en Unidades y presentaciones antes de emitir la guía.',
      );
    }
    return unit;
  }

  static double _baseQuantity(
    Map<String, dynamic> item,
    Map<String, dynamic>? snapshot,
  ) {
    final snap = snapshot?['base_quantity'];
    if (snap is num && snap.toDouble().isFinite && snap > 0) {
      return snap.toDouble();
    }
    final scale = (item['stock_scale_snapshot'] as num?)?.toDouble() ?? 1;
    final stored = (item['piezas_reales'] as num?)?.toDouble();
    if (stored != null && scale > 0) return stored / scale;
    return (item['cantidad'] as num?)?.toDouble() ?? 0;
  }

  static Map<String, dynamic> desdeVenta(
    Map<String, dynamic> item,
    Map<String, dynamic> producto,
  ) {
    if (esServicio(producto)) {
      throw const FormatException(
        'Los servicios no forman parte de la mercancía trasladada en una GRE.',
      );
    }
    final presentation = _snapshot(item);
    final cantidadComercial = presentation?['quantity'] is num
        ? (presentation!['quantity'] as num).toDouble()
        : (item['cantidad'] as num?)?.toDouble() ?? 0;
    final piezas =
        (item['piezas_reales'] as num?)?.toInt() ?? cantidadComercial.toInt();
    final cantidadBase = _baseQuantity(item, presentation);
    final cantidad = presentation == null ? cantidadComercial : cantidadBase;
    final pesoUnidad = (producto['peso_kg'] as num?)?.toDouble() ?? 0;
    final productName = producto['nombre']?.toString() ?? 'Producto';

    return {
      'producto_id': (item['producto_id'] as num?)?.toInt(),
      'producto_data': producto,
      'detalle_venta_id': (item['id'] as num?)?.toInt(),
      'almacen_id': (item['almacen_id'] as num?)?.toInt(),
      'codigo': producto['codigo']?.toString() ?? '',
      'descripcion': descripcionPresentacion(item, producto),
      'unidad': presentation == null
          ? GreItemRules.unidadSunatDesdeTipoComercial(
              item['tipo_unidad']?.toString() ?? '',
              producto,
            )
          : _requiredBaseFiscalUnit(presentation, productName),
      'cantidad': cantidad,
      'piezas_reales': piezas,
      'peso_unitario_kg': pesoUnidad,
      'peso_total_kg': pesoUnidad * cantidadBase,
      if (presentation != null) 'presentation_snapshot': presentation,
      if (item['stock_scale_snapshot'] != null)
        'stock_scale_snapshot': item['stock_scale_snapshot'],
    };
  }

  static Map<String, dynamic> desdeTraslado(
    Map<String, dynamic> traslado,
    Map<String, dynamic> producto,
  ) {
    if (esServicio(producto)) {
      throw const FormatException(
        'Un servicio no puede originar un traslado físico.',
      );
    }
    final cantidad = (traslado['cantidad'] as num?)?.toDouble() ?? 0;
    final pesoUnidad = (producto['peso_kg'] as num?)?.toDouble() ?? 0;

    return {
      'producto_id': (traslado['producto_id'] as num?)?.toInt(),
      'producto_data': producto,
      'transferencia_id': (traslado['id'] as num?)?.toInt(),
      'almacen_id': (traslado['almacen_origen_id'] as num?)?.toInt(),
      'codigo': producto['codigo']?.toString() ?? '',
      'descripcion': producto['nombre']?.toString() ?? 'Producto',
      'unidad': GreItemRules.unidadGreProducto(producto),
      'cantidad': cantidad,
      'piezas_reales': cantidad.toInt(),
      'peso_unitario_kg': pesoUnidad,
      'peso_total_kg': pesoUnidad * cantidad,
    };
  }

  static List<Map<String, dynamic>> desdeCarrito(
    List<Map<String, dynamic>> carrito, {
    int? almacenFallback,
  }) {
    final lineas = <Map<String, dynamic>>[];

    for (final item in carrito) {
      final productoRaw = item['producto_data'];
      if (productoRaw is! Map) {
        throw const FormatException(
          'No se encontró la información del producto.',
        );
      }

      final producto = Map<String, dynamic>.from(productoRaw);
      if (esServicio(producto)) continue;
      final presentation = _snapshot(item);
      final cantidadVisual = (item['cantidad'] as num?)?.toDouble() ?? 0;
      if (cantidadVisual <= 0) continue;

      final cantidadBase = presentation == null
          ? cantidadVisual
          : _baseQuantity(item, presentation);
      final tipoUnidad = StockUtils.normalizarTipoUnidad(
        item['tipo_unidad']?.toString(),
      );
      final unidadSunat = presentation == null
          ? GreItemRules.unidadSunatDesdeTipoComercial(tipoUnidad, producto)
          : _requiredBaseFiscalUnit(
              presentation,
              producto['nombre']?.toString() ?? 'Producto',
            );
      final piezasReales = presentation == null
          ? GreItemRules.calcularPiezasDetalle(
              producto: producto,
              unidadSunat: unidadSunat,
              cantidadVisual: cantidadVisual,
              piezasFallback: (item['piezas_reales'] as num?)?.toInt(),
            )
          : ((item['piezas_reales'] as num?)?.toInt() ?? cantidadBase.toInt());

      final pesoCatalogo = (producto['peso_kg'] as num?)?.toDouble() ?? 0;
      final usarPesoEspecifico = item['usar_peso_especifico'] == true;

      final double pesoTotal;
      final double pesoUnitarioBase;
      if (usarPesoEspecifico && item['peso_especifico_manual'] is num) {
        pesoTotal = (item['peso_especifico_manual'] as num).toDouble();
        pesoUnitarioBase = cantidadBase > 0 ? pesoTotal / cantidadBase : 0;
      } else {
        pesoUnitarioBase = pesoCatalogo;
        final unidadesBaseParaPeso = presentation == null
            ? piezasReales.toDouble()
            : cantidadBase;
        pesoTotal = pesoUnitarioBase * unidadesBaseParaPeso;
      }

      lineas.add({
        'producto_id': (producto['id'] as num).toInt(),
        'producto_data': producto,
        'almacen_id': (item['almacen_id'] as num?)?.toInt() ?? almacenFallback,
        'codigo': producto['codigo']?.toString() ?? '',
        'descripcion': descripcionPresentacion(item, producto),
        'unidad': unidadSunat,
        'cantidad': cantidadBase,
        'piezas_reales': piezasReales,
        'peso_unitario_kg': pesoUnitarioBase,
        'peso_total_kg': pesoTotal,
        'precio_unitario': (item['precio_unitario'] as num?)?.toDouble() ?? 0.0,
        if (presentation != null) 'presentation_snapshot': presentation,
        if (item['stock_scale_snapshot'] != null)
          'stock_scale_snapshot': item['stock_scale_snapshot'],
      });
    }

    return lineas;
  }

  static String descripcionPresentacion(
    Map<String, dynamic> item,
    Map<String, dynamic> producto,
  ) {
    final nombre = producto['nombre']?.toString() ?? 'Producto';
    final presentation = _snapshot(item);
    if (presentation != null && presentation['singular'] != null) {
      final factor = (presentation['factor'] as num?)?.toDouble() ?? 1;
      final factorText = factor == factor.roundToDouble()
          ? factor.toInt().toString()
          : factor.toString();
      return (factor - 1).abs() > 0.000001
          ? '$nombre - ${presentation['singular']} x $factorText'
          : '$nombre - ${presentation['singular']}';
    }
    final tipoUnidad = item['tipo_unidad']?.toString().toLowerCase() ?? '';
    final pcs =
        (item['pcs_snapshot'] as num?)?.toInt() ??
        (producto['cantidad_por_caja'] as num?)?.toInt() ??
        1;

    if (tipoUnidad == 'caja') return '$nombre - Caja x $pcs';
    if (tipoUnidad == 'paquete') return '$nombre - Paquete';
    return '$nombre - Unidad';
  }
}
