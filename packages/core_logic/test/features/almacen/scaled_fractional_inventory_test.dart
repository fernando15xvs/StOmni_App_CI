import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProductUnitConfiguration kilograms() => ProductUnitConfiguration(
    revision: 3,
    profile: ProductUnitProfile(
      baseUnit: CommercialPresentation(
        code: 'kg',
        singularLabel: 'kg',
        pluralLabel: 'kg',
        baseQuantity: 1,
        allowsFractionalSale: true,
        quantityPrecision: 3,
      ),
      presentations: [
        CommercialPresentation(
          code: 'kg',
          singularLabel: 'kg',
          pluralLabel: 'kg',
          baseQuantity: 1,
          allowsFractionalSale: true,
          quantityPrecision: 3,
        ),
        CommercialPresentation(
          code: 'saco_25',
          singularLabel: 'Saco',
          pluralLabel: 'Sacos',
          baseQuantity: 25,
          allowsFractionalSale: false,
          quantityPrecision: 0,
        ),
      ],
    ),
  );

  test('kg precision 3 maps visible stock to integer minor units', () {
    final configuration = kilograms();

    expect(configuration.storageScale, 1000);
    expect(configuration.toStoredBaseQuantity(0.5), 500);
    expect(configuration.toStoredBaseQuantity(10.5), 10500);
    expect(configuration.fromStoredBaseQuantity(10500), 10.5);
    expect(configuration.storedQuantityFor('saco_25', 2), 50000);
  });

  test(
    'configured sale line preserves visible, base and stored quantities',
    () {
      final configuration = kilograms();
      final line = SaleCartLine(
        productId: 9,
        warehouseId: 2,
        quantity: 0.5,
        subtotal: 6,
        commercialUnit: 'kg',
        commercialUnitPrice: 12,
        baseUnitPrice: 12,
        product: SaleProductSnapshot(
          name: 'Cable por peso',
          defaultUnitPrice: 12,
          unitConfiguration: configuration,
        ),
      );

      final mapped = SaleLinePersistenceMapper.map(line, requireExactTotals: true);

      expect(mapped.quantity, 0.5);
      expect(mapped.baseQuantity, 0.5);
      expect(mapped.storedBaseQuantity, 500);
      expect(mapped.storageScale, 1000);
      expect(mapped.presentationRevision, 3);
    },
  );

  test(
    'profile rejects commercial precision that cannot map to base scale',
    () {
      expect(
        () => ProductUnitConfiguration(
          revision: 1,
          profile: ProductUnitProfile(
            baseUnit: CommercialPresentation(
              code: 'metro',
              singularLabel: 'Metro',
              pluralLabel: 'Metros',
              baseQuantity: 1,
              allowsFractionalSale: true,
              quantityPrecision: 2,
            ),
            presentations: [
              CommercialPresentation(
                code: 'metro',
                singularLabel: 'Metro',
                pluralLabel: 'Metros',
                baseQuantity: 1,
                allowsFractionalSale: true,
                quantityPrecision: 2,
              ),
              CommercialPresentation(
                code: 'rollo',
                singularLabel: 'Rollo',
                pluralLabel: 'Rollos',
                baseQuantity: 0.333,
                allowsFractionalSale: true,
                quantityPrecision: 3,
              ),
            ],
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test('discrete preset profiles keep scale one', () {
    final profile = StockUtils.unitProfileForSaleType(
      SaleUnitType.cajaUnidades,
      unitsPerPackage: 12,
    );
    final configuration = ProductUnitConfiguration(
      revision: 1,
      profile: profile,
    );

    expect(configuration.storageScale, 1);
    expect(configuration.toStoredBaseQuantity(24), 24);
    expect(configuration.fromStoredBaseQuantity(24), 24);
  });
}
