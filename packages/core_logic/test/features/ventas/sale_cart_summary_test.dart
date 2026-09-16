import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SaleCartSummaryFormatter usa etiquetas comerciales configurables', () {
    final cart = SaleCart([
      SaleCartLine(
        productId: 1,
        quantity: 2.5,
        subtotal: 25,
        commercialUnit: 'metro',
      ),
      SaleCartLine(
        productId: 2,
        quantity: 3,
        subtotal: 30,
        commercialUnit: 'rollo_100',
      ),
    ]);

    final meter = CommercialPresentation.base(
      code: 'metro',
      singularLabel: 'Metro',
      pluralLabel: 'Metros',
      allowsFractionalSale: true,
    );
    final roll = CommercialPresentation(
      code: 'rollo_100',
      singularLabel: 'Rollo',
      pluralLabel: 'Rollos',
      baseQuantity: 100,
    );

    expect(
      SaleCartSummaryFormatter.format(
        cart,
        presentations: {meter.code: meter, roll.code: roll},
      ),
      '2.5 Metros · 3 Rollos',
    );
  });

  test('SaleCartSummaryFormatter conserva fallback legacy', () {
    final cart = SaleCart([
      SaleCartLine(
        productId: 1,
        quantity: 2,
        subtotal: 20,
        commercialUnit: 'unidad',
      ),
    ]);

    expect(SaleCartSummaryFormatter.format(cart), '2 unidades');
  });

  test('infiere etiquetas de los perfiles versionados del carrito', () {
    final bottle = CommercialPresentation.base(
      code: 'botella',
      singularLabel: 'Botella',
      pluralLabel: 'Botellas',
    );
    final pack = CommercialPresentation(
      code: 'pack_6',
      singularLabel: 'Pack',
      pluralLabel: 'Packs',
      baseQuantity: 6,
    );
    final product = SaleProductSnapshot(
      name: 'Agua',
      unitConfiguration: ProductUnitConfiguration(
        revision: 2,
        profile: ProductUnitProfile(
          baseUnit: bottle,
          presentations: [bottle, pack],
        ),
      ),
    );
    final cart = SaleCart([
      SaleCartLine(
        productId: 1,
        quantity: 2,
        subtotal: 20,
        commercialUnit: 'pack_6',
        product: product,
      ),
    ]);

    expect(SaleCartSummaryFormatter.format(cart), '2 Packs');
  });
}
