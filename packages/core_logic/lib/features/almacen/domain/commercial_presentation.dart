import 'quantity.dart';

/// Presentación comercial genérica de un producto.
///
/// El inventario se expresa en una unidad base y cada presentación define
/// cuántas unidades base representa. No contiene conceptos de ferretería ni de
/// una interfaz concreta.
class CommercialPresentation {
  CommercialPresentation({
    required String code,
    required this.singularLabel,
    required this.pluralLabel,
    required this.baseQuantity,
    String? fiscalUnitCode,
    bool allowsFractionalSale = false,
    int? quantityPrecision,
  }) : code = normalizeCode(code),
       fiscalUnitCode = normalizeFiscalUnitCode(fiscalUnitCode),
       quantityPrecision = quantityPrecision ?? (allowsFractionalSale ? 3 : 0) {
    if (this.code.isEmpty) {
      throw ArgumentError.value(code, 'code', 'La presentación requiere código.');
    }
    if (singularLabel.trim().isEmpty || pluralLabel.trim().isEmpty) {
      throw ArgumentError('La presentación requiere etiquetas visibles.');
    }
    if (!baseQuantity.isFinite || baseQuantity <= 0) {
      throw ArgumentError.value(
        baseQuantity,
        'baseQuantity',
        'La equivalencia debe ser mayor que cero.',
      );
    }
    if (this.quantityPrecision < 0 ||
        this.quantityPrecision > FixedQuantity.maxScale) {
      throw ArgumentError.value(
        this.quantityPrecision,
        'quantityPrecision',
        'La precisión de venta debe estar entre 0 y ${FixedQuantity.maxScale}.',
      );
    }
  }

  /// Identificador técnico estable, por ejemplo `unidad`, `kg`, `pack_6`.
  final String code;
  final String singularLabel;
  final String pluralLabel;

  /// Código fiscal/tributario de unidad (por ejemplo, el catálogo configurado
  /// por la política fiscal). Es opcional para operaciones internas y se exige
  /// en el boundary fiscal cuando corresponde emitir un documento electrónico.
  final String? fiscalUnitCode;

  /// Cantidad de la unidad base representada por una unidad comercial.
  final double baseQuantity;

  /// Número máximo de decimales aceptados para la cantidad comercial.
  final int quantityPrecision;

  /// Compatibilidad con consumidores anteriores.
  bool get allowsFractionalSale => quantityPrecision > 0;

  factory CommercialPresentation.base({
    required String code,
    required String singularLabel,
    required String pluralLabel,
    String? fiscalUnitCode,
    bool allowsFractionalSale = false,
    int? quantityPrecision,
  }) {
    return CommercialPresentation(
      code: code,
      singularLabel: singularLabel,
      pluralLabel: pluralLabel,
      fiscalUnitCode: fiscalUnitCode,
      baseQuantity: 1,
      allowsFractionalSale: allowsFractionalSale,
      quantityPrecision: quantityPrecision,
    );
  }

  FixedQuantity commercialQuantity(double value) {
    final quantity = FixedQuantity.fromDouble(
      value,
      scale: quantityPrecision,
    );
    if (quantity.isNegative) {
      throw ArgumentError.value(
        value,
        'value',
        'La cantidad comercial no puede ser negativa.',
      );
    }
    return quantity;
  }

  double toBaseQuantity(double commercialQuantity) {
    final quantity = this.commercialQuantity(commercialQuantity);
    return quantity.value * baseQuantity;
  }

  double fromBaseQuantity(double quantity) {
    if (!quantity.isFinite || quantity < 0) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'La cantidad base no puede ser negativa ni no finita.',
      );
    }
    return quantity / baseQuantity;
  }

  String labelFor(double quantity) {
    final singular = (quantity - 1).abs() < 0.000001;
    return singular ? singularLabel : pluralLabel;
  }

  String format(double quantity) =>
      '${commercialQuantity(quantity).format()} ${labelFor(quantity)}';

  static String formatNumber(double quantity) {
    if (quantity == quantity.truncateToDouble()) {
      return quantity.toInt().toString();
    }
    return quantity
        .toStringAsFixed(FixedQuantity.maxScale)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String normalizeCode(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  static String? normalizeFiscalUnitCode(String? raw) {
    final value = raw?.trim().toUpperCase() ?? '';
    if (value.isEmpty) return null;
    if (!RegExp(r'^[A-Z0-9]{1,6}$').hasMatch(value)) {
      throw ArgumentError.value(
        raw,
        'fiscalUnitCode',
        'El código fiscal debe contener entre 1 y 6 caracteres alfanuméricos.',
      );
    }
    return value;
  }
}

/// Configuración de unidades y presentaciones vendibles de un producto.
class ProductUnitProfile {
  ProductUnitProfile({
    required this.baseUnit,
    required Iterable<CommercialPresentation> presentations,
  }) : presentations = List<CommercialPresentation>.unmodifiable(presentations) {
    final seen = <String>{};
    for (final presentation in this.presentations) {
      if (!seen.add(presentation.code)) {
        throw ArgumentError(
          'La presentación ${presentation.code} está definida más de una vez.',
        );
      }
    }
    if (!seen.contains(baseUnit.code)) {
      throw ArgumentError(
        'La unidad base ${baseUnit.code} debe estar incluida entre las presentaciones vendibles.',
      );
    }
    if ((baseUnit.baseQuantity - 1).abs() > 0.000001) {
      throw ArgumentError('La unidad base debe tener equivalencia 1.');
    }
    final storedBase = find(baseUnit.code)!;
    if (storedBase.baseQuantity != 1 ||
        storedBase.singularLabel != baseUnit.singularLabel ||
        storedBase.pluralLabel != baseUnit.pluralLabel ||
        storedBase.fiscalUnitCode != baseUnit.fiscalUnitCode ||
        storedBase.quantityPrecision != baseUnit.quantityPrecision) {
      throw ArgumentError('La presentación base debe coincidir con la unidad base.');
    }
  }

  final CommercialPresentation baseUnit;
  final List<CommercialPresentation> presentations;

  CommercialPresentation? find(String code) {
    final normalized = CommercialPresentation.normalizeCode(code);
    for (final presentation in presentations) {
      if (presentation.code == normalized) return presentation;
    }
    return null;
  }

  bool supports(String code) => find(code) != null;

  double toBaseQuantity({
    required String presentationCode,
    required double quantity,
  }) {
    final presentation = find(presentationCode);
    if (presentation == null) {
      throw ArgumentError.value(
        presentationCode,
        'presentationCode',
        'La presentación no pertenece al producto.',
      );
    }
    return presentation.toBaseQuantity(quantity);
  }

  String formatBaseQuantity(double quantity, {String separator = ' y '}) {
    if (!quantity.isFinite || quantity < 0) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'La cantidad base no puede ser negativa ni no finita.',
      );
    }

    if (baseUnit.allowsFractionalSale ||
        quantity != quantity.truncateToDouble()) {
      return baseUnit.format(quantity);
    }

    var remaining = quantity.toInt();
    final candidates = presentations
        .where(
          (presentation) =>
              presentation.code != baseUnit.code &&
              presentation.baseQuantity > 1 &&
              presentation.baseQuantity == presentation.baseQuantity.roundToDouble(),
        )
        .toList(growable: false)
      ..sort((a, b) {
        final byQuantity = b.baseQuantity.compareTo(a.baseQuantity);
        return byQuantity != 0 ? byQuantity : a.code.compareTo(b.code);
      });

    final parts = <String>[];
    for (final presentation in candidates) {
      final factor = presentation.baseQuantity.toInt();
      if (factor <= 1) continue;
      final count = remaining ~/ factor;
      if (count <= 0) continue;
      parts.add(presentation.format(count.toDouble()));
      remaining %= factor;
    }

    if (remaining > 0 || parts.isEmpty) {
      parts.add(baseUnit.format(remaining.toDouble()));
    }
    return parts.join(separator);
  }
}
