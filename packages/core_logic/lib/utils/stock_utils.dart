import '../features/almacen/domain/commercial_presentation.dart';

enum SaleUnitType {
  unidad,
  caja,
  paquete,
  cajaPaquetes,
  cajaUnidades,
}

class StockUtils {
  static const _customDisplayPrefix = 'custom_display:';

  static SaleUnitType getTipoVentaFromString(String tipoDb) {
    final tipo = tipoDb.trim();
    if (tipo != tipoDb || tipo != tipo.toUpperCase()) {
      throw FormatException('tipo_venta no canónico: "$tipoDb".');
    }

    return switch (tipo) {
      'UNIDAD' => SaleUnitType.unidad,
      'CAJA' => SaleUnitType.caja,
      'PAQUETE' => SaleUnitType.paquete,
      'CAJA_PAQUETES' => SaleUnitType.cajaPaquetes,
      'CAJA_UNIDADES' => SaleUnitType.cajaUnidades,
      _ => throw FormatException(
        'tipo_venta no canónico: "$tipoDb".',
      ),
    };
  }

  static SaleUnitType getTipoVentaFromMap(Map<String, dynamic> producto) {
    final tipoDb = (producto['tipo_venta'] ?? '').toString().trim();
    if (tipoDb.isEmpty) {
      throw const FormatException('Producto sin tipo_venta canónico.');
    }
    return getTipoVentaFromString(tipoDb);
  }

  static String toDatabaseValue(SaleUnitType tipoVenta) {
    return switch (tipoVenta) {
      SaleUnitType.unidad => 'UNIDAD',
      SaleUnitType.caja => 'CAJA',
      SaleUnitType.paquete => 'PAQUETE',
      SaleUnitType.cajaPaquetes => 'CAJA_PAQUETES',
      SaleUnitType.cajaUnidades => 'CAJA_UNIDADES',
    };
  }

  static String displayName(SaleUnitType tipoVenta) {
    return switch (tipoVenta) {
      SaleUnitType.unidad => 'Unidad',
      SaleUnitType.caja => 'Caja',
      SaleUnitType.paquete => 'Paquete',
      SaleUnitType.cajaPaquetes => 'Caja + paquetes',
      SaleUnitType.cajaUnidades => 'Caja + unidades',
    };
  }

  /// Construye el perfil comercial canónico para el tipo de venta del producto.
  static ProductUnitProfile unitProfileForSaleType(
    SaleUnitType tipoVenta, {
    int unitsPerPackage = 1,
  }) {
    final factor = unitsPerPackage > 0 ? unitsPerPackage.toDouble() : 1.0;

    CommercialPresentation unit({
      required String code,
      required String singular,
      required String plural,
    }) => CommercialPresentation.base(
      code: code,
      singularLabel: singular,
      pluralLabel: plural,
    );

    switch (tipoVenta) {
      case SaleUnitType.paquete:
        final base = unit(
          code: 'paquete',
          singular: 'Paquete',
          plural: 'Paquetes',
        );
        return ProductUnitProfile(baseUnit: base, presentations: [base]);
      case SaleUnitType.cajaPaquetes:
        final base = unit(
          code: 'paquete',
          singular: 'Paquete',
          plural: 'Paquetes',
        );
        return ProductUnitProfile(
          baseUnit: base,
          presentations: [
            base,
            CommercialPresentation(
              code: 'caja',
              singularLabel: 'Caja',
              pluralLabel: 'Cajas',
              baseQuantity: factor,
            ),
          ],
        );
      case SaleUnitType.cajaUnidades:
        final base = unit(
          code: 'unidad',
          singular: 'Unidad',
          plural: 'Unidades',
        );
        return ProductUnitProfile(
          baseUnit: base,
          presentations: [
            base,
            CommercialPresentation(
              code: 'caja',
              singularLabel: 'Caja',
              pluralLabel: 'Cajas',
              baseQuantity: factor,
            ),
          ],
        );
      case SaleUnitType.caja:
        final base = unit(code: 'caja', singular: 'Caja', plural: 'Cajas');
        return ProductUnitProfile(baseUnit: base, presentations: [base]);
      case SaleUnitType.unidad:
        final base = unit(
          code: 'unidad',
          singular: 'Unidad',
          plural: 'Unidades',
        );
        return ProductUnitProfile(baseUnit: base, presentations: [base]);
    }
  }

  static bool esMixto(SaleUnitType tipoVenta) {
    return tipoVenta == SaleUnitType.cajaPaquetes ||
        tipoVenta == SaleUnitType.cajaUnidades;
  }

  static bool usaPaquetesComoBase(SaleUnitType tipoVenta) {
    return tipoVenta == SaleUnitType.paquete ||
        tipoVenta == SaleUnitType.cajaPaquetes ||
        tipoVenta == SaleUnitType.caja;
  }

  static bool usaUnidadesComoBase(SaleUnitType tipoVenta) {
    return tipoVenta == SaleUnitType.cajaUnidades ||
        tipoVenta == SaleUnitType.unidad;
  }

  static bool usaContenidoInformativo(SaleUnitType tipoVenta, int contenido) {
    if (contenido <= 1) return false;
    return tipoVenta != SaleUnitType.unidad;
  }

  static String unidadBaseSingular(SaleUnitType tipoVenta) =>
      unitProfileForSaleType(tipoVenta).baseUnit.singularLabel;

  static String unidadBasePlural(SaleUnitType tipoVenta) =>
      unitProfileForSaleType(tipoVenta).baseUnit.pluralLabel;

  static String etiquetaContenidoEmpaque(SaleUnitType tipoVenta) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
      case SaleUnitType.caja:
        return 'Piezas por Paquete';
      case SaleUnitType.cajaPaquetes:
        return 'Paquetes por Caja';
      case SaleUnitType.cajaUnidades:
        return 'Unidades por Caja';
      case SaleUnitType.unidad:
        return 'Unidades';
    }
  }

  static String descripcionContenido(int contenido, SaleUnitType tipoVenta) {
    return '$contenido ${etiquetaContenidoEmpaque(tipoVenta)}';
  }

  static String descripcionContenidoCorta(
    int contenido,
    SaleUnitType tipoVenta,
  ) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
      case SaleUnitType.caja:
        return '$contenido PCS/PAQ';
      case SaleUnitType.cajaPaquetes:
        return '$contenido PAQ/CAJA';
      case SaleUnitType.cajaUnidades:
        return '$contenido UND/CAJA';
      case SaleUnitType.unidad:
        return '$contenido UND';
    }
  }

  static String etiquetaContenido(SaleUnitType tipoVenta, int pcs) {
    return descripcionContenidoCorta(pcs, tipoVenta);
  }

  /// Codifica una etiqueta exclusivamente visual para presentaciones
  /// configurables. No debe persistirse como tipo de venta del producto.
  static String customDisplayUnit(String label) {
    final normalized = label.trim();
    if (normalized.isEmpty) return 'unidad';
    return '$_customDisplayPrefix${Uri.encodeComponent(normalized)}';
  }

  static String normalizarTipoUnidad(String? valor) {
    final raw = (valor ?? '').trim();
    final lower = raw.toLowerCase();
    if (lower.startsWith(_customDisplayPrefix)) {
      return '$_customDisplayPrefix${raw.substring(_customDisplayPrefix.length)}';
    }
    final tipo = lower;
    if (const {'caja', 'cajas', 'box', 'bx'}.contains(tipo)) return 'caja';
    if (const {'paquete', 'paquetes', 'paq', 'pack', 'pk'}.contains(tipo)) {
      return 'paquete';
    }
    if (const {
      'unidad',
      'unidades',
      'und',
      'niu',
      'pieza',
      'piezas',
    }.contains(tipo)) {
      return 'unidad';
    }
    return tipo;
  }

  static bool permiteUnidadComercial(
    SaleUnitType tipoVenta,
    String tipoUnidad,
  ) {
    final unidad = normalizarTipoUnidad(tipoUnidad);
    return unitProfileForSaleType(tipoVenta).supports(unidad);
  }

  static String tipoUnidadSuelta(SaleUnitType tipoVenta) =>
      unitProfileForSaleType(tipoVenta).baseUnit.code;

  static String etiquetaUnidadComercial(String tipoUnidad, {int cantidad = 2}) {
    final unidad = normalizarTipoUnidad(tipoUnidad);
    if (unidad.startsWith(_customDisplayPrefix)) {
      final encoded = unidad.substring(_customDisplayPrefix.length);
      try {
        return Uri.decodeComponent(encoded);
      } catch (_) {
        return cantidad == 1 ? 'Unidad' : 'Unidades';
      }
    }
    final singular = cantidad == 1;
    switch (unidad) {
      case 'caja':
        return singular ? 'Caja' : 'Cajas';
      case 'paquete':
        return singular ? 'Paquete' : 'Paquetes';
      default:
        return singular ? 'Unidad' : 'Unidades';
    }
  }

  /// Convierte una entrada caja/suelto a la cantidad base.
  /// La equivalencia real se resuelve mediante [ProductUnitProfile].
  static int calcularTotalPiezas({
    required int cajas,
    required int unidades,
    required SaleUnitType tipoVenta,
    required int pcs,
  }) {
    final profile = unitProfileForSaleType(tipoVenta, unitsPerPackage: pcs);

    switch (tipoVenta) {
      case SaleUnitType.paquete:
      case SaleUnitType.unidad:
        return profile
            .toBaseQuantity(
              presentationCode: profile.baseUnit.code,
              quantity: unidades.toDouble(),
            )
            .round();
      case SaleUnitType.caja:
        return profile
            .toBaseQuantity(
              presentationCode: profile.baseUnit.code,
              quantity: cajas.toDouble(),
            )
            .round();
      case SaleUnitType.cajaPaquetes:
      case SaleUnitType.cajaUnidades:
        final packaged = profile.toBaseQuantity(
          presentationCode: 'caja',
          quantity: cajas.toDouble(),
        );
        final loose = profile.toBaseQuantity(
          presentationCode: profile.baseUnit.code,
          quantity: unidades.toDouble(),
        );
        return (packaged + loose).round();
    }
  }

  static int calcularCantidadBaseVenta({
    required SaleUnitType tipoVenta,
    required String tipoUnidad,
    required int cantidadVisual,
    required int pcs,
  }) {
    final unidad = normalizarTipoUnidad(tipoUnidad);
    final profile = unitProfileForSaleType(tipoVenta, unitsPerPackage: pcs);
    if (!profile.supports(unidad)) {
      throw ArgumentError(
        '${displayName(tipoVenta)} no permite venta por $tipoUnidad.',
      );
    }
    if (cantidadVisual <= 0) return 0;
    return profile
        .toBaseQuantity(
          presentationCode: unidad,
          quantity: cantidadVisual.toDouble(),
        )
        .round();
  }

  static double precioComercialPredeterminado({
    required SaleUnitType tipoVenta,
    required String tipoUnidad,
    required double precioUnidad,
    required double precioCajaBase,
    required int pcs,
  }) {
    final unidad = normalizarTipoUnidad(tipoUnidad);
    final equivalencia = pcs > 0 ? pcs : 1;

    if (unidad == 'caja') {
      final base = precioCajaBase > 0 ? precioCajaBase : precioUnidad;
      return base * equivalencia;
    }

    if (unidad == 'paquete') {
      if (tipoVenta == SaleUnitType.paquete) {
        final precioPieza = precioCajaBase > 0 ? precioCajaBase : precioUnidad;
        return precioPieza * equivalencia;
      }
      return precioUnidad > 0 ? precioUnidad : precioCajaBase;
    }

    return precioUnidad > 0 ? precioUnidad : precioCajaBase;
  }

  static double precioBaseStockDesdeComercial({
    required SaleUnitType tipoVenta,
    required String tipoUnidad,
    required double precioComercial,
    required int pcs,
  }) {
    final unidad = normalizarTipoUnidad(tipoUnidad);
    final profile = unitProfileForSaleType(tipoVenta, unitsPerPackage: pcs);
    final presentation = profile.find(unidad);

    if (presentation != null && presentation.baseQuantity > 1) {
      return precioComercial / presentation.baseQuantity;
    }

    return precioComercial;
  }

  /// Auxiliar de precio base para consumidores que todavía operan con
  /// precio de unidad/empaque.
  static double calcularPrecioUnitario({
    required double precioUnidad,
    required double precioCaja,
    required int pcs,
    required String tipoUnidad,
  }) {
    if (normalizarTipoUnidad(tipoUnidad) == 'caja') {
      return precioCaja > 0 ? precioCaja : precioUnidad;
    }
    return precioUnidad > 0 ? precioUnidad : precioCaja;
  }

  static double calcularPrecioEmpaqueCompleto({
    required double precioBaseEmpaque,
    required int pcs,
  }) {
    if (precioBaseEmpaque <= 0) return 0;
    return precioBaseEmpaque * (pcs > 0 ? pcs : 1);
  }

  static int boxesFromUnits(int totalBase, int contenidoPorCaja) {
    if (contenidoPorCaja <= 1) return 0;
    return totalBase ~/ contenidoPorCaja;
  }

  static int looseUnitsFromTotal(int totalBase, int contenidoPorCaja) {
    if (contenidoPorCaja <= 1) return totalBase;
    return totalBase % contenidoPorCaja;
  }

  static String formatStock(
    int totalBase,
    int contenidoPorCaja,
    SaleUnitType type,
  ) {
    final totalSeguro = totalBase < 0 ? 0 : totalBase;
    return unitProfileForSaleType(
      type,
      unitsPerPackage: contenidoPorCaja,
    ).formatBaseQuantity(totalSeguro.toDouble());
  }
}
