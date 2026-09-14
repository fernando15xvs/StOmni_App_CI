import '../../../utils/stock_utils.dart';
import '../../almacen/domain/product_unit_configuration.dart';
import '../domain/sale_cart.dart';
import 'sale_processing_models.dart';

/// Convierte una línea de carrito al contrato transaccional de venta.
class LegacySaleLineMapper {
  const LegacySaleLineMapper._();

  static SaleProcessingLine map(
    SaleCartLine line, {
    bool requireExactTotals = false,
  }) {
    final productId = line.productId;
    final warehouseId = line.warehouseId;
    final quantity = line.quantity;
    if (!quantity.isFinite || quantity <= 0) {
      throw StateError('Hay una línea de venta con cantidad inválida.');
    }
    if (productId <= 0 || warehouseId <= 0) {
      throw StateError('Hay una línea de venta incompleta.');
    }

    final tipoVenta = line.product.saleType;
    final pcs = line.product.unitsPerPackage;
    final configuration = line.product.unitConfiguration;
    if (configuration == null && quantity != quantity.roundToDouble()) {
      throw StateError(
        'Este producto legacy no admite cantidad fraccionaria. '
        'Configura una unidad base con precisión decimal antes de vender fracciones.',
      );
    }
    final unitCode = line.product.normalizeUnit(line.commercialUnit);
    final presentation = line.product.commercialProfile.find(unitCode);
    if (presentation == null) {
      throw StateError(
        '${line.product.name} no admite la presentación seleccionada.',
      );
    }

    late final double baseQuantity;
    late final int storedBaseQuantity;
    late final int storageScale;
    if (configuration == null) {
      if (pcs <= 0) {
        throw StateError(
          'Este producto legacy requiere una cantidad entera válida.',
        );
      }
      final legacyBase = StockUtils.calcularCantidadBaseVenta(
        tipoVenta: tipoVenta,
        tipoUnidad: unitCode,
        cantidadVisual: quantity.toInt(),
        pcs: pcs,
      );
      baseQuantity = legacyBase.toDouble();
      storedBaseQuantity = legacyBase;
      storageScale = 1;
    } else {
      try {
        baseQuantity = PresentationPolicy.baseQuantity(
          configuration.profile,
          unitCode,
          quantity,
        );
        storedBaseQuantity = configuration.toStoredBaseQuantity(baseQuantity);
        storageScale = configuration.storageScale;
      } on ArgumentError catch (error) {
        throw StateError(error.message?.toString() ?? 'Cantidad no válida.');
      }
    }

    final recorded = line.recordedBaseQuantity;
    if (recorded != null && (recorded - baseQuantity).abs() > 0.000001) {
      throw StateError(
        'La cantidad base de ${line.product.name} cambió. '
        'Vuelve a seleccionar el producto.',
      );
    }

    final serials = line.serialNumbers.map((value) => value.trim()).toList(growable: false);
    if (serials.any((value) => value.isEmpty) ||
        serials.toSet().length != serials.length) {
      throw StateError('La selección de números de serie contiene valores inválidos.');
    }

    final subtotal = line.subtotal;
    final commercialUnitPrice = line.commercialUnitPrice;
    final baseUnitPrice = line.baseUnitPrice;
    if (!subtotal.isFinite ||
        subtotal < 0 ||
        !commercialUnitPrice.isFinite ||
        commercialUnitPrice < 0 ||
        !baseUnitPrice.isFinite ||
        baseUnitPrice < 0 ||
        baseQuantity <= 0 ||
        storedBaseQuantity <= 0) {
      throw StateError(
        'Hay una línea de venta con importes o cantidad base inválidos.',
      );
    }

    final expectedCommercialPrice = subtotal / quantity;
    final expectedBasePrice = subtotal / baseQuantity;
    if ((commercialUnitPrice - expectedCommercialPrice).abs() > 0.02 ||
        (baseUnitPrice - expectedBasePrice).abs() > 0.02 ||
        (requireExactTotals &&
            ((subtotal - quantity * commercialUnitPrice).abs() > 0.020000001 ||
                (subtotal - baseQuantity * baseUnitPrice).abs() >
                    0.020000001))) {
      throw StateError(
        'Los precios de ${line.product.name} no son consistentes. '
        'Regresa a Definir Precios.',
      );
    }

    return SaleProcessingLine(
      productId: productId,
      warehouseId: warehouseId,
      quantity: quantity,
      baseQuantity: baseQuantity,
      storedBaseQuantity: storedBaseQuantity,
      storageScale: storageScale,
      unitCode: unitCode,
      baseUnitLabel: line.product.commercialProfile.baseUnit.singularLabel,
      commercialUnitPrice: commercialUnitPrice,
      baseUnitPrice: baseUnitPrice,
      subtotal: subtotal,
      presentationRevision: configuration?.revision,
      commercialUnitLabel: presentation.singularLabel,
      fiscalUnitCode: configuration == null ? null : presentation.fiscalUnitCode,
      serialNumbers: List<String>.unmodifiable(serials),
    );
  }
}
