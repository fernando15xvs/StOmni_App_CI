import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'acepta cantidad fraccionaria cuando el producto tiene perfil configurado',
    () {
      final base = CommercialPresentation.base(
        code: 'kg',
        singularLabel: 'Kilogramo',
        pluralLabel: 'Kilogramos',
        fiscalUnitCode: 'KGM',
        quantityPrecision: 3,
      );
      final configuration = ProductUnitConfiguration(
        revision: 1,
        profile: ProductUnitProfile(baseUnit: base, presentations: [base]),
      );
      final line = SaleCartLine(
        productId: 10,
        warehouseId: 2,
        product: SaleProductSnapshot(
          name: 'Cable por peso',
          saleType: SaleUnitType.unidad,
          unitConfiguration: configuration,
        ),
        quantity: 0.5,
        subtotal: 0,
        commercialUnit: 'kg',
      );

      final priced = const PriceSaleLineUseCase().execute(
        line,
        commercialUnitPrice: 20,
      );

      expect(priced.quantity, 0.5);
      expect(priced.recordedBaseQuantity, 0.5);
      expect(priced.subtotal, 10);
      expect(priced.baseUnitPrice, 20);
      final persisted = SaleLinePersistenceMapper.map(priced);
      expect(persisted.baseQuantity, 0.5);
      expect(persisted.storedBaseQuantity, 500);
      expect(persisted.storageScale, 1000);
    },
  );

  test('mantiene cantidad entera para productos sin perfil configurable', () {
    final line = SaleCartLine(
      productId: 10,
      warehouseId: 2,
      product: const SaleProductSnapshot(
        name: 'Producto estándar',
        saleType: SaleUnitType.unidad,
      ),
      quantity: 0.5,
      subtotal: 0,
      commercialUnit: 'unidad',
    );

    expect(
      () => const PriceSaleLineUseCase().execute(line, commercialUnitPrice: 20),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('entera'),
        ),
      ),
    );
  });
}
