import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SaleTotals', () {
    test('calcula descuento porcentual', () {
      final totals = SaleTotals.calculate(
        subtotal: 200,
        discountInput: 10,
        discountMode: SaleDiscountMode.percentage,
      );

      expect(totals.discountAmount, 20);
      expect(totals.discountPercentage, 10);
      expect(totals.total, 180);
      expect(totals.hasDiscount, isTrue);
    });

    test('calcula descuento por monto fijo', () {
      final totals = SaleTotals.calculate(
        subtotal: 250,
        discountInput: 25,
        discountMode: SaleDiscountMode.fixedAmount,
      );

      expect(totals.discountAmount, 25);
      expect(totals.discountPercentage, 10);
      expect(totals.total, 225);
    });

    test('sin descuento conserva subtotal', () {
      final totals = SaleTotals.calculate(
        subtotal: 99.90,
        discountInput: 0,
        discountMode: SaleDiscountMode.percentage,
      );

      expect(totals.discountAmount, 0);
      expect(totals.discountPercentage, 0);
      expect(totals.total, 99.90);
      expect(totals.hasDiscount, isFalse);
    });

    test('el total nunca baja de cero', () {
      final totals = SaleTotals.calculate(
        subtotal: 50,
        discountInput: 80,
        discountMode: SaleDiscountMode.fixedAmount,
      );

      expect(totals.discountAmount, 80);
      expect(totals.total, 0);
    });

    test('entradas no finitas no contaminan el cálculo', () {
      final totals = SaleTotals.calculate(
        subtotal: 100,
        discountInput: double.nan,
        discountMode: SaleDiscountMode.fixedAmount,
      );

      expect(totals.discountAmount, 0);
      expect(totals.total, 100);
    });
  });
}
