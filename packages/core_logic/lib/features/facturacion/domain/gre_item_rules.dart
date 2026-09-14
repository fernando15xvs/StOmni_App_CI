import '../../../utils/stock_utils.dart';

/// Reglas puras para convertir las presentaciones comerciales del inventario
/// a cantidades y unidades usadas por la GRE.
///
/// No accede a Flutter, Supabase ni estado de UI, por lo que puede validarse
/// con tests unitarios y reutilizarse desde formularios/controladores GRE.
class GreItemRules {
  const GreItemRules._();

  static String unidadBaseProducto(Map<String, dynamic> producto) {
    final tipo = producto['tipo_venta']?.toString().toUpperCase() ?? '';
    return tipo == 'PAQUETES' || tipo == 'CAJA_PAQUETES' ? 'PK' : 'NIU';
  }

  static String unidadGreProducto(Map<String, dynamic> producto) {
    final base = unidadBaseProducto(producto);
    final configured =
        producto['unidad_gre']?.toString().trim().toUpperCase() ?? '';

    if (configured.isEmpty || (configured == 'NIU' && base == 'PK')) {
      return base;
    }
    return configured;
  }

  static String tipoComercialDesdeUnidadSunat(String unidad) {
    return switch (unidad.trim().toUpperCase()) {
      'BX' => 'caja',
      'PK' => 'paquete',
      'NIU' => 'unidad',
      _ => unidad.trim().toLowerCase(),
    };
  }

  static String unidadSunatDesdeTipoComercial(
    String tipoUnidad,
    Map<String, dynamic> producto,
  ) {
    final normalizada = StockUtils.normalizarTipoUnidad(tipoUnidad);
    return switch (normalizada) {
      'caja' => 'BX',
      'paquete' => 'PK',
      'unidad' => 'NIU',
      _ => unidadGreProducto(producto),
    };
  }

  static List<String> unidadesPermitidas(
    Map<String, dynamic>? producto,
    String unidadActual,
  ) {
    if (producto == null) {
      return const ['NIU', 'PK', 'BX', 'ZZ'];
    }

    final tipo = StockUtils.getTipoVentaFromMap(producto);
    final unidades = switch (tipo) {
      SaleUnitType.paquete => <String>['PK'],
      SaleUnitType.cajaPaquetes => <String>['BX', 'PK'],
      SaleUnitType.cajaUnidades || SaleUnitType.ambos => <String>['BX', 'NIU'],
      SaleUnitType.caja => <String>['BX'],
      SaleUnitType.unidad => <String>['NIU'],
    };

    final actual = unidadActual.trim().toUpperCase();
    if (actual.isNotEmpty && !unidades.contains(actual)) {
      unidades.add(actual);
    }
    return unidades;
  }

  static int calcularPiezasDetalle({
    required Map<String, dynamic>? producto,
    required String unidadSunat,
    required double cantidadVisual,
    int? piezasFallback,
  }) {
    final unidad = unidadSunat.trim().toUpperCase();

    if (cantidadVisual <= 0) {
      throw const FormatException('La cantidad debe ser mayor a cero.');
    }

    if (unidad == 'ZZ') {
      final fallback = piezasFallback ?? cantidadVisual.round();
      if (fallback <= 0) {
        throw const FormatException(
          'La unidad personalizada requiere piezas reales mayores a cero.',
        );
      }
      return fallback;
    }

    final cantidadEntera = cantidadVisual.round();
    if ((cantidadVisual - cantidadEntera).abs() > 0.000001) {
      throw const FormatException(
        'Las cajas, paquetes y unidades deben usar cantidades enteras.',
      );
    }

    if (producto == null) {
      return cantidadEntera;
    }

    final tipoVenta = StockUtils.getTipoVentaFromMap(producto);
    final pcs = ((producto['cantidad_por_caja'] as num?)?.toInt() ?? 1)
        .clamp(1, 1 << 31)
        .toInt();

    return StockUtils.calcularCantidadBaseVenta(
      tipoVenta: tipoVenta,
      tipoUnidad: tipoComercialDesdeUnidadSunat(unidad),
      cantidadVisual: cantidadEntera,
      pcs: pcs,
    );
  }

  static String nombreUnidad(String code) {
    switch (code.toUpperCase()) {
      case 'NIU':
        return 'Unidad';
      case 'PK':
        return 'Paquete';
      case 'BX':
        return 'Caja';
      case 'KGM':
        return 'Kilogramo';
      case 'ZZ':
        return 'Otra';
      default:
        return code;
    }
  }
}
