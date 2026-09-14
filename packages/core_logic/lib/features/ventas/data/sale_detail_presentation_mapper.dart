import '../../almacen/domain/commercial_presentation.dart';
import '../../almacen/domain/product_unit_configuration.dart';
import '../../almacen/domain/quantity.dart';

class SaleDetailPresentationMapper {
  const SaleDetailPresentationMapper._();

  /// Restaura la presentación comercial sin alterar la cantidad menor que quedó
  /// persistida para inventario/anulación.
  static Map<String, dynamic> restore(Map<String, dynamic> row) {
    final raw = row['presentation_snapshot'];
    if (raw is! Map) return row;
    final snapshot = Map<String, dynamic>.from(raw);
    final version = snapshot['schema_version'];
    if (version != 1 && version != 2) {
      throw const FormatException(
        'La presentación histórica de la venta está dañada.',
      );
    }

    final revision = _positiveInteger(snapshot['revision'], 'revisión');
    final quantity = version == 1
        ? _positiveInteger(snapshot['quantity'], 'cantidad').toDouble()
        : _positiveNumber(snapshot['quantity'], 'cantidad');
    final factor = version == 1
        ? _positiveInteger(snapshot['factor'], 'equivalencia').toDouble()
        : _positiveNumber(snapshot['factor'], 'equivalencia');
    final storageScale = version == 1
        ? 1
        : _positiveInteger(snapshot['storage_scale'], 'escala de stock');
    if (storageScale > 1000000) {
      throw const FormatException('La escala histórica de stock es inválida.');
    }

    final baseQuantity = snapshot['base_quantity'] == null
        ? quantity * factor
        : _positiveNumber(snapshot['base_quantity'], 'cantidad base');
    if ((baseQuantity - quantity * factor).abs() > 0.000001) {
      throw const FormatException(
        'La equivalencia histórica de la presentación está dañada.',
      );
    }
    late final int expectedStored;
    try {
      expectedStored = FixedQuantity.fromDouble(
        baseQuantity,
        scale: _scaleFromStorage(storageScale),
      ).minorUnits;
    } on ArgumentError {
      throw const FormatException(
        'La cantidad histórica no coincide con la escala de inventario.',
      );
    }
    final storedBase = _positiveInteger(row['piezas_reales'], 'cantidad base');
    if (storedBase != expectedStored) {
      throw const FormatException(
        'La presentación histórica no coincide con el inventario descontado.',
      );
    }

    final price = _nonNegativeNumber(
      snapshot['commercial_price'],
      'precio comercial',
    );
    final code = _code(snapshot['code'], 'presentación');
    final baseCode = _code(snapshot['base_code'], 'unidad base');
    final singular = _label(snapshot['singular'], 'etiqueta singular');
    final plural = _label(snapshot['plural'], 'etiqueta plural');
    final baseLabel = _label(snapshot['base_label'], 'etiqueta base');
    final subtotal = row['subtotal'];
    if (subtotal is num &&
        (!subtotal.toDouble().isFinite ||
            (subtotal.toDouble() - quantity * price).abs() > 0.02)) {
      throw const FormatException(
        'El subtotal histórico no coincide con la presentación.',
      );
    }

    return <String, dynamic>{
      ...row,
      'cantidad': quantity,
      'cantidad_base_comercial': baseQuantity,
      'tipo_unidad': code,
      'precio_unitario_comercial': price,
      'unidad_base_snapshot': baseLabel,
      'commercial_unit_label_snapshot': singular,
      'commercial_unit_plural_snapshot': plural,
      'unit_profile_revision_snapshot': revision,
      'unit_base_code_snapshot': baseCode,
      'stock_scale_snapshot': storageScale,
    };
  }

  static List<Map<String, dynamic>> restoreMany(Object? rows) {
    if (rows is! List) {
      throw const FormatException('Los detalles de venta son inválidos.');
    }
    return rows.map((row) {
      if (row is! Map) {
        throw const FormatException('Detalle de venta inválido.');
      }
      return restore(Map<String, dynamic>.from(row));
    }).toList(growable: false);
  }

  static int _scaleFromStorage(int scale) {
    var current = 1;
    for (var precision = 0; precision <= FixedQuantity.maxScale; precision++) {
      if (current == scale) return precision;
      current *= 10;
    }
    throw const FormatException('La escala de inventario no es decimal válida.');
  }

  static int _positiveInteger(Object? raw, String field) {
    if (raw is! num ||
        !raw.toDouble().isFinite ||
        raw != raw.roundToDouble() ||
        raw <= 0 ||
        raw > PresentationPolicy.maxStoredQuantity) {
      throw FormatException('La $field histórica está dañada.');
    }
    return raw.toInt();
  }

  static double _positiveNumber(Object? raw, String field) {
    if (raw is! num || !raw.toDouble().isFinite || raw <= 0) {
      throw FormatException('La $field histórica está dañada.');
    }
    return raw.toDouble();
  }

  static double _nonNegativeNumber(Object? raw, String field) {
    if (raw is! num || !raw.toDouble().isFinite || raw < 0) {
      throw FormatException('El $field histórico está dañado.');
    }
    return raw.toDouble();
  }

  static String _code(Object? raw, String field) {
    if (raw is! String ||
        CommercialPresentation.normalizeCode(raw) != raw ||
        !RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(raw)) {
      throw FormatException('El código de $field histórico está dañado.');
    }
    return raw;
  }

  static String _label(Object? raw, String field) {
    if (raw is! String || raw.trim().isEmpty || raw.trim().length > 60) {
      throw FormatException('La $field histórica está dañada.');
    }
    return raw.trim();
  }
}
