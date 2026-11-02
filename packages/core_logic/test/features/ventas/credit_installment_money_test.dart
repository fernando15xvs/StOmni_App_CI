import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  final saleDate = DateTime(2026, 11, 2);

  SaleCreditTerms terms(List<double> amounts, {List<int>? days}) {
    return SaleCreditTerms(
      installments: [
        for (var i = 0; i < amounts.length; i++)
          SaleCreditInstallment(
            number: i + 1,
            amount: amounts[i],
            dueDate: DateTime(2026, 12, days?[i] ?? i + 1),
          ),
      ],
    );
  }

  test('rejects one-cent underpayment and overpayment', () {
    for (final amount in [99.99, 100.01]) {
      expect(
        terms([amount]).validate(saleDate: saleDate, amountDue: 100),
        isNotNull,
      );
    }
  });

  test('accepts exact cent allocation including rounding remainder', () {
    expect(
      terms([33.33, 33.33, 33.34]).validate(
        saleDate: saleDate,
        amountDue: 100,
      ),
      isNull,
    );
    expect(
      terms([0.1, 0.2]).validate(saleDate: saleDate, amountDue: 0.3),
      isNull,
    );
  });

  test('rejects sub-cent amounts even when they add to the balance', () {
    expect(
      terms([0.005, 0.005]).validate(saleDate: saleDate, amountDue: 0.01),
      isNotNull,
    );
    expect(
      terms([1]).validate(saleDate: saleDate, amountDue: 1.001),
      isNotNull,
    );
  });

  test('rejects descending dates and accepts equal due dates', () {
    expect(
      terms([50, 50], days: [2, 1]).validate(
        saleDate: saleDate,
        amountDue: 100,
      ),
      isNotNull,
    );
    expect(
      terms([50, 50], days: [1, 1]).validate(
        saleDate: saleDate,
        amountDue: 100,
      ),
      isNull,
    );
  });
}
