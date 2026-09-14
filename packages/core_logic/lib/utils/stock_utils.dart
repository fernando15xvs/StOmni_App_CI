import '../features/almacen/domain/commercial_presentation.dart';

enum SaleUnitType {
  paquete,
  cajaPaquetes,
  cajaUnidades,

  // Compatibilidad histórica durante la migración.
  unidad,
  caja,
  ambos,
}

class StockUtils {
  static const _customDisplayPrefix = 'custom_display:';

  static SaleUnitType getTipoVentaFromString(String tipoDb) {
    final tipo = tipoDb.trim().toUpperCase();

    switch (tipo) {
      case 'PAQUETES':
      case 'PAQUETE':
        return SaleUnitType.paquete;
      case 'CAJA_PAQUETES':
      case 'CAJA+PAQUETES':
      case 'CAJA + PAQUETES':
        return SaleUnitType.cajaPaquetes;
      case 'CAJA_UNIDADES':
      case 'CAJA+UNIDADES':
      case 'CAJA + UNIDADES':
        return SaleUnitType.cajaUnidades;
      case 'CAJA':
      case 'SOLO_CAJAS':
        return SaleUnitType.caja;
      case 'UNIDAD':
      case 'SOLO_UNIDADES':
        return SaleUnitType.unidad;
      case 'AMBOS':
      case 'CAJA_UNIDAD':
      case 'CAJAS_UNIDADES':
        return SaleUnitType.ambos;
      default:
        return SaleUnitType.cajaUnidades;
    }
  }

  static SaleUnitType getTipoVentaFromMap(Map<String, dynamic> producto) {
    final tipoDb = (producto['tipo_venta'] ?? '').toString();
    if (tipoDb.trim().isNotEmpty) {
      return getTipoVentaFromString(tipoDb);
    }

    final unidadMedida = (producto['unidad_medida'] ?? '')
        .toString()
        .toLowerCase();
    final pcs = (producto['cantidad_por_caja'] as num?)?.toInt() ?? 1;

    if (unidadMedida.contains('paquete')) return SaleUnitType.paquete;
    if (unidadMedida.contains('caja') && pcs > 1) return SaleUnitType.ambos;
    if (unidadMedida.contains('caja')) return SaleUnitType.caja;
    return SaleUnitType.unidad;
  }

  static SaleUnitType toOfficialType(SaleUnitType tipoVenta) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
      case SaleUnitType.cajaPaquetes:
      case SaleUnitType.cajaUnidades:
        return tipoVenta;
      case SaleUnitType.caja:
      case SaleUnitType.unidad:
        return SaleUnitType.paquete;
      case SaleUnitType.ambos:
        return SaleUnitType.cajaUnidades;
    }
  }

  static String toDatabaseValue(SaleUnitType tipoVenta) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
        return 'PAQUETES';
      case SaleUnitType.cajaPaquetes:
        return 'CAJA_PAQUETES';
      case SaleUnitType.cajaUnidades:
        return 'CAJA_UNIDADES';
      case SaleUnitType.caja:
        return 'SOLO_CAJAS';
      case SaleUnitType.unidad:
        return 'SOLO_UNIDADES';
      case SaleUnitType.ambos:
        return 'AMBOS';
    }
  }

  static String displayName(SaleUnitType tipoVenta) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
        return 'Paquetes';
      case SaleUnitType.cajaPaquetes:
        return 'Caja + Paquetes';
      case SaleUnitType.cajaUnidades:
        return 'Caja + Unidades';
      case SaleUnitType.caja:
        return 'Cajas (anterior)';
      case SaleUnitType.unidad:
        return 'Unidades (anterior)';
      case SaleUnitType.ambos:
        return 'Caja + Unidades (anterior)';
    }
  }

  /// Traduce el contrato histórico `SaleUnitType` al modelo comercial genérico.
  ///
  /// Toda lógica nueva puede trabajar directamente con [ProductUnitProfile].
  /// Este método existe para que la base de datos y las pantallas actuales
  /// continúen funcionando durante la migración.
  static ProductUnitProfile legacyUnitProfile(
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
      case SaleUnitType.ambos:
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
        final base = unit(
          code: 'caja',
          singular: 'Caja',
          plural: 'Cajas',
        );
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
        tipoVenta == SaleUnitType.cajaUnidades ||
        tipoVenta == SaleUnitType.ambos;
  }

  static bool usaPaquetesComoBase(SaleUnitType tipoVenta) {
    return tipoVenta == SaleUnitType.paquete ||
        tipoVenta == SaleUnitType.cajaPaquetes ||
        tipoVenta == SaleUnitType.caja;
  }

  static bool usaUnidadesComoBase(SaleUnitType tipoVenta) {
    return tipoVenta == SaleUnitType.cajaUnidades ||
        tipoVenta == SaleUnitType.unidad ||
        tipoVenta == SaleUnitType.ambos;
  }

  static bool usaContenidoInformativo(SaleUnitType tipoVenta, int contenido) {
    if (contenido <= 1) return false;
    return tipoVenta != SaleUnitType.unidad;
  }

  static String unidadBaseSingular(SaleUnitType tipoVenta) =>
      legacyUnitProfile(tipoVenta).baseUnit.singularLabel;

  static String unidadBasePlural(SaleUnitType tipoVenta) =>
      legacyUnitProfile(tipoVenta).baseUnit.pluralLabel;

  static String etiquetaContenidoEmpaque(SaleUnitType tipoVenta) {
    switch (tipoVenta) {
      case SaleUnitType.paquete:
      case SaleUnitType.caja:
        return 'Piezas por Paquete';
      case SaleUnitType.cajaPaquetes:
        return 'Paquetes por Caja';
      case SaleUnitType.cajaUnidades:
      case SaleUnitType.ambos:
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
      case SaleUnitType.ambos:
        return '$contenido UND/CAJA';
      case SaleUnitType.unidad:
        return '$contenido UND';
    }
  }

  static String etiquetaContenido(SaleUnitType tipoVenta, int pcs) {
    return descripcionContenidoCorta(pcs, tipoVenta);
  }

  /// Codifica una etiqueta exclusivamente visual dentro del campo legacy de
  /// unidad. No debe persistirse: los mappers de lectura la usan para que UIs
  /// antiguas puedan mostrar presentaciones configurables sin interpretar su
  /// código técnico.
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
    return legacyUnitProfile(tipoVenta).supports(unidad);
  }

  static String tipoUnidadSuelta(SaleUnitType tipoVenta) =>
      legacyUnitProfile(tipoVenta).baseUnit.code;

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

  /// Convierte la entrada histórica caja/suelto a la cantidad base.
  /// La equivalencia real se resuelve mediante [ProductUnitProfile].
  static int calcularTotalPiezas({
    required int cajas,
    required int unidades,
    required SaleUnitType tipoVenta,
    required int pcs,
  }) {
    final profile = legacyUnitProfile(
      tipoVenta,
      unitsPerPackage: pcs,
    );

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
      case SaleUnitType.ambos:
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
    final profile = legacyUnitProfile(
      tipoVenta,
      unitsPerPackage: pcs,
    );
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
    final profile = legacyUnitProfile(
      tipoVenta,
      unitsPerPackage: pcs,
    );
    final presentation = profile.find(unidad);

    if (presentation != null && presentation.baseQuantity > 1) {
      return precioComercial / presentation.baseQuantity;
    }

    return precioComercial;
  }

  /// Método histórico conservado para módulos aún no migrados.
  /// Los módulos nuevos deben usar [precioBaseStockDesdeComercial].
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
    return legacyUnitProfile(
      type,
      unitsPerPackage: contenidoPorCaja,
    ).formatBaseQuantity(totalSeguro.toDouble());
  }
}
