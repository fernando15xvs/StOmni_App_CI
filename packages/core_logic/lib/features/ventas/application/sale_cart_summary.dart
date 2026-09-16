import '../../almacen/domain/commercial_presentation.dart';
import '../domain/sale_cart.dart';

class SaleCartSummaryFormatter {
  const SaleCartSummaryFormatter._();

  /// Formatea el resumen del carrito usando etiquetas configurables cuando el
  /// cliente dispone de ellas. Las claves del mapa son códigos normalizados de
  /// presentación (`kg`, `metro`, `rollo_100`, etc.).
  ///
  /// El fallback conserva las etiquetas legacy mientras las pantallas actuales
  /// terminan de migrar sus perfiles de producto.
  static String format(
    SaleCart cart, {
    Map<String, CommercialPresentation> presentations = const {},
  }) {
    if (presentations.isEmpty &&
        cart.lines.any((line) => line.product.unitConfiguration != null)) {
      final grouped =
          <String, ({double quantity, CommercialPresentation unit})>{};
      var complete = true;
      for (final line in cart.lines) {
        if (line.quantity <= 0) continue;
        final code = line.product.normalizeUnit(line.commercialUnit);
        final unit = line.product.commercialProfile.find(code);
        if (unit == null) {
          complete = false;
          break;
        }
        final key =
            '${unit.code}\u0000${unit.singularLabel}\u0000${unit.pluralLabel}';
        final previous = grouped[key];
        grouped[key] = (
          quantity: (previous?.quantity ?? 0) + line.quantity,
          unit: unit,
        );
      }
      if (complete && grouped.isNotEmpty) {
        return grouped.values
            .map((entry) => entry.unit.format(entry.quantity))
            .join(' · ');
      }
    }
    final quantities = cart.quantitiesByUnit;
    if (quantities.isEmpty) return 'Sin productos';

    return quantities.entries
        .map(
          (entry) => _formatQuantity(
            entry.key,
            entry.value,
            presentations: presentations,
          ),
        )
        .join(' · ');
  }

  static String _formatQuantity(
    String unit,
    double quantity, {
    required Map<String, CommercialPresentation> presentations,
  }) {
    final normalized = CommercialPresentation.normalizeCode(unit);
    final configured = presentations[normalized];
    if (configured != null) {
      return configured.format(quantity);
    }

    final singular = switch (normalized) {
      'caja' => 'caja',
      'paquete' => 'paquete',
      'unidad' => 'unidad',
      _ => normalized.isEmpty ? 'unidad' : normalized,
    };
    final plural = switch (normalized) {
      'caja' => 'cajas',
      'paquete' => 'paquetes',
      'unidad' => 'unidades',
      _ => singular,
    };

    return '${CommercialPresentation.formatNumber(quantity)} '
        '${(quantity - 1).abs() < 0.000001 ? singular : plural}';
  }
}
