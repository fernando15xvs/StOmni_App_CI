import '../../../utils/stock_utils.dart';
import '../../almacen/domain/product_unit_configuration.dart';
import '../domain/sale_cart.dart';
import 'legacy_sale_line_mapper.dart';

/// Aplica el precio comercial y deriva importes/equivalencias en el core.
class PriceSaleLineUseCase {
  const PriceSaleLineUseCase();

  SaleCartLine execute(
    SaleCartLine line, {
    required double commercialUnitPrice,
  }) {
    final configuration = line.product.unitConfiguration;
    if (!line.quantity.isFinite || line.quantity <= 0) {
      throw StateError('La cantidad debe ser positiva y válida.');
    }
    if (!commercialUnitPrice.isFinite ||
        commercialUnitPrice < 0 ||
        (configuration == null && line.product.unitsPerPackage <= 0)) {
      throw StateError(
        'El precio o la equivalencia del producto no es válido.',
      );
    }

    final unit = line.product.normalizeUnit(line.commercialUnit);
    late final double baseQuantity;
    if (configuration == null) {
      if (line.quantity != line.quantity.roundToDouble()) {
        throw StateError(
          'Este producto legacy requiere una cantidad entera válida.',
        );
      }
      baseQuantity = StockUtils.calcularCantidadBaseVenta(
        tipoVenta: line.product.saleType,
        tipoUnidad: unit,
        cantidadVisual: line.quantity.toInt(),
        pcs: line.product.unitsPerPackage,
      ).toDouble();
    } else {
      try {
        baseQuantity = PresentationPolicy.baseQuantity(
          configuration.profile,
          unit,
          line.quantity,
        );
        configuration.toStoredBaseQuantity(baseQuantity);
      } on ArgumentError catch (error) {
        throw StateError(
          error.message?.toString() ?? 'La cantidad seleccionada no es válida.',
        );
      }
    }

    final priced = SaleCartLine(
      productId: line.productId,
      warehouseId: line.warehouseId,
      warehouseName: line.warehouseName,
      product: line.product,
      quantity: line.quantity,
      commercialUnit: unit,
      commercialUnitPrice: commercialUnitPrice,
      baseUnitPrice: commercialUnitPrice * line.quantity / baseQuantity,
      subtotal: line.quantity * commercialUnitPrice,
      recordedBaseQuantity: baseQuantity,
      manualTotalWeightKg: line.manualTotalWeightKg,
      serialNumbers: line.serialNumbers,
    );
    LegacySaleLineMapper.map(priced);
    return priced;
  }
}
