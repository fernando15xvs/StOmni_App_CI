import 'stock_utils.dart';

/// Formatea movimientos de inventario usando primero las fotografías
/// históricas guardadas en inventario_movimientos.
///
/// Nunca depende del tipo o PCS actual del producto cuando el movimiento ya
/// contiene tipo_venta_snapshot, unidad_base_snapshot y pcs.
class InventarioMovimientoUtils {
  const InventarioMovimientoUtils._();

  static int toInt(dynamic value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double toDouble(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static Map<String, dynamic> productoActual(Map<String, dynamic> movimiento) {
    final raw = movimiento['productos'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  static String tipoVentaSnapshot(Map<String, dynamic> movimiento) {
    final snapshot = movimiento['tipo_venta_snapshot']?.toString().trim();
    if (snapshot != null && snapshot.isNotEmpty) return snapshot;

    final producto = productoActual(movimiento);
    return producto['tipo_venta']?.toString().trim() ?? '';
  }

  static SaleUnitType tipoVenta(Map<String, dynamic> movimiento) {
    final tipo = tipoVentaSnapshot(movimiento);
    if (tipo.isNotEmpty) return StockUtils.getTipoVentaFromString(tipo);
    return StockUtils.getTipoVentaFromMap(productoActual(movimiento));
  }

  static int pcs(Map<String, dynamic> movimiento) {
    final snapshot = toInt(movimiento['pcs'], fallback: 1);
    if (snapshot > 0) return snapshot;

    final producto = productoActual(movimiento);
    final actual = toInt(producto['cantidad_por_caja'], fallback: 1);
    return actual > 0 ? actual : 1;
  }

  static String unidadBase(Map<String, dynamic> movimiento) {
    final tipo = tipoVenta(movimiento);

    if (tipo == SaleUnitType.caja) return 'Caja';

    final snapshot = movimiento['unidad_base_snapshot']?.toString().trim();
    if (snapshot != null && snapshot.isNotEmpty) {
      final normalizada = StockUtils.normalizarTipoUnidad(snapshot);
      if (normalizada == 'caja') return 'Caja';
      if (normalizada == 'paquete') return 'Paquete';
      if (normalizada == 'unidad') return 'Unidad';
    }

    return StockUtils.unidadBaseSingular(tipo);
  }

  static String unidadBasePlural(Map<String, dynamic> movimiento) {
    switch (unidadBase(movimiento)) {
      case 'Caja':
        return 'Cajas';
      case 'Paquete':
        return 'Paquetes';
      default:
        return 'Unidades';
    }
  }

  static bool tieneIngreso(Map<String, dynamic> movimiento) {
    return toDouble(movimiento['ingreso_cant']) > 0;
  }

  static bool tieneSalida(Map<String, dynamic> movimiento) {
    return toDouble(movimiento['salida_cant']) > 0;
  }

  static bool esTraslado(Map<String, dynamic> movimiento) {
    final tipo = (movimiento['tipo'] ?? '').toString().toUpperCase();
    final obs = (movimiento['observaciones'] ?? '').toString().toLowerCase();
    return tipo.contains('TRASLADO') || obs.contains('traslado');
  }

  static String clasificacion(Map<String, dynamic> movimiento) {
    if (esTraslado(movimiento)) {
      return 'traslado';
    }

    final ingreso = tieneIngreso(movimiento);
    final salida = tieneSalida(movimiento);

    if (ingreso && !salida) {
      return 'ingreso';
    }

    if (salida && !ingreso) {
      return 'salida';
    }

    return 'desconocido';
  }

  static String subtipo(Map<String, dynamic> movimiento) {
    final clasif = clasificacion(movimiento);

    if (clasif == 'desconocido') {
      return 'Movimiento desconocido';
    }

    final tipo = (movimiento['tipo'] ?? '').toString().toUpperCase();
    final obs = (movimiento['observaciones'] ?? '').toString().toLowerCase();

    if (esTraslado(movimiento)) {
      if (tipo.contains('ENTRADA') || tieneIngreso(movimiento)) {
        return 'Entrada - Traslado';
      }
      return 'Salida - Traslado';
    }

    if (tieneIngreso(movimiento) || tipo == 'ENTRADA' || tipo == 'INGRESO') {
      if (obs.contains('anulación') ||
          obs.contains('anulacion') ||
          obs.contains('devolución') ||
          obs.contains('devolucion')) {
        return 'Entrada - Devolución';
      }
      if (obs.contains('ajuste') || obs.contains('merma')) {
        return 'Entrada - Ajuste';
      }
      return 'Entrada - Compra';
    }

    if (tipo == 'MERMA' || obs.contains('merma') || obs.contains('ajuste')) {
      return 'Salida - Ajuste';
    }
    if (obs.contains('anulación') ||
        obs.contains('anulacion') ||
        obs.contains('devolución') ||
        obs.contains('devolucion')) {
      return 'Salida - Devolución';
    }
    return 'Salida - Venta';
  }

  static int cantidadMovimiento(Map<String, dynamic> movimiento) {
    if (tieneIngreso(movimiento)) {
      return toInt(movimiento['ingreso_cant']).abs();
    }
    if (tieneSalida(movimiento)) {
      return toInt(movimiento['salida_cant']).abs();
    }
    return toInt(movimiento['cantidad']).abs();
  }

  static String formatCantidad(
    Map<String, dynamic> movimiento,
    dynamic cantidad, {
    bool compacta = false,
  }) {
    final rawQty = toInt(cantidad);
    final sign = rawQty < 0 ? '-' : '';
    final qty = rawQty.abs();
    final tipo = tipoVenta(movimiento);
    final contenido = pcs(movimiento);

    if (compacta) {
      switch (tipo) {
        case SaleUnitType.paquete:
          return '$sign${qty}P';
        case SaleUnitType.cajaPaquetes:
          if (contenido <= 1) return '$sign${qty}P';
          final cajas = qty ~/ contenido;
          final paquetes = qty % contenido;
          if (cajas == 0) return '$sign${paquetes}P';
          if (paquetes == 0) return '$sign${cajas}C';
          return '$sign${cajas}C ${paquetes}P';
        case SaleUnitType.cajaUnidades:
          if (contenido <= 1) return '$sign${qty}U';
          final cajas = qty ~/ contenido;
          final unidades = qty % contenido;
          if (cajas == 0) return '$sign${unidades}U';
          if (unidades == 0) return '$sign${cajas}C';
          return '$sign${cajas}C ${unidades}U';
        case SaleUnitType.caja:
          return '$sign${qty}C';
        case SaleUnitType.unidad:
          return '$sign${qty}U';
      }
    }

    return '$sign${StockUtils.formatStock(qty, contenido, tipo)}';
  }

  static String formatCantidadMovimiento(
    Map<String, dynamic> movimiento, {
    bool compacta = false,
  }) {
    return formatCantidad(
      movimiento,
      cantidadMovimiento(movimiento),
      compacta: compacta,
    );
  }

  static String firmaFormato(Map<String, dynamic> movimiento) {
    return '${tipoVentaSnapshot(movimiento).toUpperCase()}|${pcs(movimiento)}|${unidadBase(movimiento)}';
  }

  static String? codigoProducto(Map<String, dynamic> movimiento) {
    final codigo = productoActual(movimiento)['codigo']?.toString().trim();
    return codigo == null || codigo.isEmpty ? null : codigo;
  }
}
