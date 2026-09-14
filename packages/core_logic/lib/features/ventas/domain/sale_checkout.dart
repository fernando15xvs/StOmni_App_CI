import 'sale_models.dart';
import 'sale_totals.dart';

class SalePaymentInput {
  const SalePaymentInput({required this.method, required this.amount});

  final String method;
  final double amount;
}

/// Reglas puras del checkout de una venta.
///
/// No conoce TextEditingController, Riverpod ni widgets. La interfaz convierte
/// sus campos de texto a valores numéricos y delega aquí los cálculos y la
/// construcción de pagos que luego consume el caso de uso de venta.
class SaleCheckout {
  const SaleCheckout._();

  static SaleTotals calculateTotals({
    required double subtotal,
    required double discountInput,
    required bool discountIsPercentage,
  }) {
    return SaleTotals.calculate(
      subtotal: subtotal,
      discountInput: discountInput,
      discountMode: discountIsPercentage
          ? SaleDiscountMode.percentage
          : SaleDiscountMode.fixedAmount,
    );
  }

  static double totalPaid(Iterable<SalePaymentInput> payments) {
    return payments.fold<double>(0, (total, payment) {
      final amount = payment.amount;
      if (!amount.isFinite || amount <= 0) return total;
      return total + amount;
    });
  }

  static List<SalePayment> buildPayments({
    required bool isCredit,
    required Iterable<SalePaymentInput> cashPayments,
    required double initialPayment,
    required String initialPaymentMethod,
  }) {
    if (isCredit) {
      if (!initialPayment.isFinite || initialPayment <= 0) {
        return const <SalePayment>[];
      }
      return <SalePayment>[
        SalePayment(
          metodo: initialPaymentMethod.trim().isEmpty
              ? 'Efectivo'
              : initialPaymentMethod.trim(),
          monto: initialPayment,
        ),
      ];
    }

    return cashPayments
        .where((payment) => payment.amount.isFinite && payment.amount > 0)
        .map(
          (payment) => SalePayment(
            metodo: payment.method.trim().isEmpty
                ? 'Efectivo'
                : payment.method.trim(),
            monto: payment.amount,
          ),
        )
        .toList(growable: false);
  }
}
