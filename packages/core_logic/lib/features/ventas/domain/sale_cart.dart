import '../../../utils/stock_utils.dart';
import 'sale_product_snapshot.dart';

/// Línea de carrito independiente de cualquier widget o framework de estado.
///
/// La serialización histórica pertenece a data/SaleCartMapper.
class SaleCartLine {
  const SaleCartLine({
    required this.productId,
    required this.quantity,
    required this.subtotal,
    required this.commercialUnit,
    this.warehouseId = 0,
    this.warehouseName = '',
    this.product = const SaleProductSnapshot(),
    this.commercialUnitPrice = 0,
    this.baseUnitPrice = 0,
    this.recordedBaseQuantity,
    this.manualTotalWeightKg,
    this.serialNumbers = const <String>[],
  });

  final int productId;
  final double quantity;
  final double subtotal;
  final String commercialUnit;
  final int warehouseId;
  final String warehouseName;
  final SaleProductSnapshot product;
  final double commercialUnitPrice;
  final double baseUnitPrice;
  final double? recordedBaseQuantity;
  final double? manualTotalWeightKg;

  /// Identidades físicas seleccionadas para productos con seguimiento serial.
  /// Vacío para productos normales o por lote (los lotes se consumen FEFO).
  final List<String> serialNumbers;
}

/// Carrito de venta inmutable y reutilizable por cualquier interfaz.
class SaleCart {
  SaleCart(Iterable<SaleCartLine> lines)
    : lines = List<SaleCartLine>.unmodifiable(lines);

  factory SaleCart.empty() => SaleCart(const <SaleCartLine>[]);

  final List<SaleCartLine> lines;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get lineCount => lines.length;

  double get totalAmount => lines.fold<double>(
    0,
    (total, line) => total + line.subtotal,
  );

  bool containsProduct(int productId) {
    return lines.any((line) => line.productId == productId);
  }

  Map<String, double> get quantitiesByUnit {
    final result = <String, double>{};
    for (final line in lines) {
      if (line.quantity <= 0) continue;
      result.update(
        line.product.normalizeUnit(line.commercialUnit),
        (current) => current + line.quantity,
        ifAbsent: () => line.quantity,
      );
    }
    return Map<String, double>.unmodifiable(result);
  }

  double quantityFor(String commercialUnit) {
    final normalized = StockUtils.normalizarTipoUnidad(commercialUnit);
    final key = normalized.isEmpty
        ? commercialUnit.trim().toLowerCase()
        : normalized;
    return quantitiesByUnit[key] ?? 0;
  }

  SaleCart replaceProductLines(
    int productId,
    Iterable<SaleCartLine> newLines,
  ) {
    final replacements = List<SaleCartLine>.of(newLines);
    if (replacements.any((line) => line.productId != productId)) {
      throw ArgumentError('Las líneas deben pertenecer al producto reemplazado.');
    }
    return SaleCart([
      ...lines.where((line) => line.productId != productId),
      ...replacements,
    ]);
  }

  SaleCart removeProduct(int productId) {
    return SaleCart(lines.where((line) => line.productId != productId));
  }
}
