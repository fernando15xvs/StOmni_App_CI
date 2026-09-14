import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop consume el mismo dominio de ventas que mobile', () {
    final totals = SaleTotals.calculate(
      subtotal: 100,
      discountInput: 10,
      discountMode: SaleDiscountMode.percentage,
    );

    expect(totals.discountAmount, 10);
    expect(totals.total, 90);
  });

  test('desktop puede construir presentaciones comerciales genéricas', () {
    final unit = CommercialPresentation.base(
      code: 'unidad',
      singularLabel: 'Unidad',
      pluralLabel: 'Unidades',
    );
    final box = CommercialPresentation(
      code: 'caja',
      singularLabel: 'Caja',
      pluralLabel: 'Cajas',
      baseQuantity: 12,
    );
    final profile = ProductUnitProfile(
      baseUnit: unit,
      presentations: [unit, box],
    );

    expect(
      profile.toBaseQuantity(presentationCode: 'caja', quantity: 2),
      24,
    );
  });
}
