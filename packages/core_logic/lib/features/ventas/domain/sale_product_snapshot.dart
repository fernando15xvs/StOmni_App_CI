import '../../../utils/stock_utils.dart';
import '../../almacen/domain/commercial_presentation.dart';
import '../../almacen/domain/product_unit_configuration.dart';

/// Datos del catálogo necesarios para reproducir una línea, incluso offline.
/// No retiene filas de base de datos ni referencias mutables a la pantalla.
class SaleProductSnapshot {
  const SaleProductSnapshot({
    this.code = '',
    this.name = 'Producto',
    this.saleType = SaleUnitType.unidad,
    this.unitsPerPackage = 1,
    this.defaultUnitPrice = 0,
    this.defaultPackageBasePrice = 0,
    this.weightKg = 0,
    this.dispatchUnit = '',
    this.unitConfiguration,
  });

  final String code;
  final String name;
  final SaleUnitType saleType;
  final int unitsPerPackage;
  final double defaultUnitPrice;
  final double defaultPackageBasePrice;
  final double weightKg;
  final String dispatchUnit;
  final ProductUnitConfiguration? unitConfiguration;

  ProductUnitProfile get commercialProfile =>
      unitConfiguration?.profile ??
      StockUtils.legacyUnitProfile(saleType, unitsPerPackage: unitsPerPackage);

  String normalizeUnit(String code) => unitConfiguration != null
      ? CommercialPresentation.normalizeCode(code)
      : StockUtils.normalizarTipoUnidad(code);

  double defaultPrice(String code) {
    if (unitConfiguration == null) {
      return StockUtils.precioComercialPredeterminado(
        tipoVenta: saleType,
        tipoUnidad: code,
        precioUnidad: defaultUnitPrice,
        precioCajaBase: defaultPackageBasePrice,
        pcs: unitsPerPackage,
      );
    }
    final unit = commercialProfile.find(code);
    if (unit == null)
      throw ArgumentError('La presentación no pertenece al producto.');
    final basePrice = StockUtils.precioComercialPredeterminado(
      tipoVenta: saleType,
      tipoUnidad: StockUtils.legacyUnitProfile(saleType).baseUnit.code,
      precioUnidad: defaultUnitPrice,
      precioCajaBase: defaultPackageBasePrice,
      pcs: unitsPerPackage,
    );
    return basePrice * unit.baseQuantity;
  }
}
