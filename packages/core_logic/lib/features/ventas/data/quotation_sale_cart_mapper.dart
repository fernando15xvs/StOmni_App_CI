import '../../../utils/stock_utils.dart';
import '../domain/sale_cart.dart';
import 'sale_cart_mapper.dart';
import 'sale_detail_presentation_mapper.dart';

class QuotationSaleCartMapper {
  const QuotationSaleCartMapper._();

  static SaleCart decode(Map<String, dynamic> quotation) {
    final details = _detailRows(quotation['detalle_cotizaciones']);
    return SaleCartMapper.decode(details.map(_cartRow));
  }

  static Map<String, dynamic> restoreForDisplay(Map<String, dynamic> detail) {
    final snapshot = _snapshot(detail);
    if (snapshot == null) return detail;
    final restored = SaleDetailPresentationMapper.restore(detail);
    final quantity = _positiveNumber(
      restored['cantidad'],
      'cantidad comercial',
    );
    final code = _requiredText(
      restored['tipo_unidad'],
      'código de presentación',
    );
    final singular = _requiredText(
      restored['commercial_unit_label_snapshot'],
      'etiqueta singular',
    );
    final plural = _requiredText(
      restored['commercial_unit_plural_snapshot'],
      'etiqueta plural',
    );
    final label = (quantity - 1).abs() < 0.000001 ? singular : plural;
    return <String, dynamic>{
      ...restored,
      'commercial_unit_code_snapshot': code,
      'display_unit_label': label,
      'tipo_unidad': StockUtils.customDisplayUnit(label),
    };
  }

  static List<Map<String, dynamic>> restoreManyForDisplay(Object? rows) {
    return _detailRows(rows).map(restoreForDisplay).toList(growable: false);
  }

  static Map<String, dynamic> documentDetail(Map<String, dynamic> detail) {
    final display = restoreForDisplay(detail);
    if (_snapshot(detail) == null) return display;
    final label = _requiredText(
      display['display_unit_label'],
      'etiqueta visual',
    );
    final originalName =
        display['producto_nombre_snapshot']?.toString().trim().isNotEmpty ==
            true
        ? display['producto_nombre_snapshot'].toString().trim()
        : (display['productos'] is Map
                  ? (display['productos'] as Map)['nombre']?.toString().trim()
                  : null) ??
              display['nombre_producto']?.toString().trim() ??
              'Producto';
    final commercialPrice = _nonNegativeNumber(
      display['precio_unitario_comercial'],
      'precio comercial',
    );
    return <String, dynamic>{
      ...display,
      'precio_unitario': commercialPrice,
      'producto_nombre_snapshot': '$originalName · $label',
    };
  }

  static List<Map<String, dynamic>> documentDetails(Object? rows) {
    return _detailRows(rows).map(documentDetail).toList(growable: false);
  }

  static Map<String, dynamic> processingDetail(Map<String, dynamic> detail) {
    final snapshot = _snapshot(detail);
    final subtotal = _number(detail['subtotal']);
    final storedQuantity = detail['piezas_reales'] == null
        ? 0
        : _integer(detail['piezas_reales']);

    if (snapshot != null) {
      final quantity = _positiveNumber(
        snapshot['quantity'],
        'cantidad comercial',
      );
      final baseQuantity = snapshot['base_quantity'] == null
          ? quantity * _positiveNumber(snapshot['factor'], 'equivalencia')
          : _positiveNumber(snapshot['base_quantity'], 'cantidad base');
      final revision = _positiveInteger(snapshot['revision'], 'revisión');
      final scale = snapshot['schema_version'] == 1
          ? 1
          : _positiveInteger(snapshot['storage_scale'], 'escala de stock');
      final code = _requiredText(snapshot['code'], 'código de presentación');
      final label = _requiredText(snapshot['singular'], 'etiqueta comercial');
      final baseLabel = _requiredText(snapshot['base_label'], 'etiqueta base');
      final commercialPrice = _nonNegativeNumber(
        snapshot['commercial_price'],
        'precio comercial',
      );
      if (storedQuantity <= 0) {
        throw const FormatException(
          'La cotización configurable no conserva stock base válido.',
        );
      }
      return <String, dynamic>{
        'producto_id': _positiveInteger(detail['producto_id'], 'producto'),
        'cantidad': quantity,
        'piezas_reales': storedQuantity,
        'cantidad_base_comercial': baseQuantity,
        'stock_scale': scale,
        'precio_unitario': subtotal / baseQuantity,
        'precio_unitario_comercial': commercialPrice,
        'subtotal': subtotal,
        'almacen_id': _positiveInteger(detail['almacen_id'], 'almacén'),
        'tipo_unidad': code,
        'unidadLabel': baseLabel,
        'unit_profile_revision': revision,
        'commercial_unit_label': label,
      };
    }

    final quantity = _integer(detail['cantidad']);
    final commercialPrice = detail['precio_unitario_comercial'] == null
        ? (quantity > 0 ? subtotal / quantity : 0.0)
        : _number(detail['precio_unitario_comercial']);
    return <String, dynamic>{
      'producto_id': detail['producto_id'],
      'cantidad': quantity,
      'piezas_reales': storedQuantity > 0 ? storedQuantity : quantity,
      'cantidad_base_comercial': storedQuantity > 0 ? storedQuantity : quantity,
      'stock_scale': 1,
      'precio_unitario': _basePrice(
        detail,
        subtotal,
        storedQuantity > 0 ? storedQuantity.toDouble() : quantity.toDouble(),
      ),
      'precio_unitario_comercial': commercialPrice,
      'subtotal': subtotal,
      'almacen_id': detail['almacen_id'],
      'tipo_unidad': StockUtils.normalizarTipoUnidad(
        detail['tipo_unidad']?.toString(),
      ),
      'unidadLabel': detail['unidad_base_snapshot'] ?? 'Unidad',
    };
  }

  static Map<String, dynamic> _cartRow(Map<String, dynamic> detail) {
    final currentProduct = Map<String, dynamic>.from(
      detail['productos'] as Map? ?? const <String, dynamic>{},
    );
    if (currentProduct.isEmpty || currentProduct['activo'] == false) {
      throw StateError(
        'Uno de los productos de la cotización ya no está disponible.',
      );
    }

    final snapshot = _snapshot(detail);
    final subtotal = _number(detail['subtotal']);
    late final double quantity;
    late final double commercialPrice;
    late final double? baseQuantity;
    late final String unitCode;

    if (snapshot != null) {
      final revision = _positiveInteger(snapshot['revision'], 'revisión');
      final profile = snapshot['profile'];
      if (profile is! Map) {
        throw const FormatException(
          'El snapshot de la cotización no conserva el perfil de unidades.',
        );
      }
      currentProduct['unit_configuration'] = <String, dynamic>{
        'revision': revision,
        'profile': Map<String, dynamic>.from(profile),
      };
      quantity = _positiveNumber(snapshot['quantity'], 'cantidad comercial');
      commercialPrice = _nonNegativeNumber(
        snapshot['commercial_price'],
        'precio comercial',
      );
      final factor = _positiveNumber(snapshot['factor'], 'equivalencia');
      baseQuantity = snapshot['base_quantity'] == null
          ? quantity * factor
          : _positiveNumber(snapshot['base_quantity'], 'cantidad base');
      unitCode = _requiredText(snapshot['code'], 'código de presentación');
    } else {
      quantity = _integer(detail['cantidad']).toDouble();
      commercialPrice = detail['precio_unitario_comercial'] == null
          ? (quantity > 0 ? subtotal / quantity : 0.0)
          : _number(detail['precio_unitario_comercial']);
      baseQuantity = detail['piezas_reales'] == null
          ? null
          : _integer(detail['piezas_reales']).toDouble();
      unitCode = StockUtils.normalizarTipoUnidad(
        detail['tipo_unidad']?.toString(),
      );
    }

    return <String, dynamic>{
      'id': detail['producto_id'],
      'producto_id': detail['producto_id'],
      'nombre':
          detail['producto_nombre_snapshot'] ??
          currentProduct['nombre'] ??
          'Producto',
      'cantidad': quantity,
      'precio': commercialPrice,
      'precio_unitario_comercial': commercialPrice,
      'precio_unitario': baseQuantity != null && baseQuantity > 0
          ? subtotal / baseQuantity
          : _number(detail['precio_unitario'] ?? 0),
      'subtotal': subtotal,
      if (baseQuantity != null) 'piezas_reales': baseQuantity,
      'tipo_unidad': unitCode,
      'almacen_id': detail['almacen_id'],
      'producto_data': currentProduct,
      'cotizacion_detalle_id': detail['id'],
      'tipo_venta_snapshot': detail['tipo_venta_snapshot'],
      'pcs_snapshot': detail['pcs_snapshot'],
      'unidad_base_snapshot':
          snapshot?['base_label'] ?? detail['unidad_base_snapshot'],
    };
  }

  static Map<String, dynamic>? _snapshot(Map<String, dynamic> detail) {
    final raw = detail['presentation_snapshot'];
    if (raw == null) return null;
    if (raw is! Map) {
      throw const FormatException('El snapshot de presentación está dañado.');
    }
    final snapshot = Map<String, dynamic>.from(raw);
    final version = snapshot['schema_version'];
    if (version != 1 && version != 2) {
      throw const FormatException(
        'La versión del snapshot de presentación no es compatible.',
      );
    }
    return snapshot;
  }

  static List<Map<String, dynamic>> _detailRows(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const FormatException('La cotización contiene detalles inválidos.');
    }
    return raw
        .map((row) {
          if (row is Map<String, dynamic>) return row;
          if (row is Map) return Map<String, dynamic>.from(row);
          throw const FormatException(
            'La cotización contiene un detalle inválido.',
          );
        })
        .toList(growable: false);
  }

  static double _basePrice(
    Map<String, dynamic> detail,
    double subtotal,
    double baseQuantity,
  ) {
    if (detail['precio_unitario'] != null) {
      return _number(detail['precio_unitario']);
    }
    return baseQuantity > 0 ? subtotal / baseQuantity : 0.0;
  }

  static double _number(Object? raw) {
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    if (value == null || !value.isFinite) {
      throw const FormatException('La cotización contiene un número inválido.');
    }
    return value;
  }

  static double _positiveNumber(Object? raw, String field) {
    final value = _number(raw);
    if (value <= 0) {
      throw FormatException('La cotización contiene $field inválido.');
    }
    return value;
  }

  static double _nonNegativeNumber(Object? raw, String field) {
    final value = _number(raw);
    if (value < 0) {
      throw FormatException('La cotización contiene $field inválido.');
    }
    return value;
  }

  static int _integer(Object? raw) {
    final value = _number(raw);
    if (value != value.roundToDouble()) {
      throw const FormatException(
        'La cotización contiene una cantidad entera inválida.',
      );
    }
    return value.toInt();
  }

  static int _positiveInteger(Object? raw, String field) {
    final value = _integer(raw);
    if (value <= 0) {
      throw FormatException('La cotización contiene $field inválido.');
    }
    return value;
  }

  static String _requiredText(Object? raw, String field) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw FormatException('La cotización no conserva $field.');
    }
    return value;
  }
}
