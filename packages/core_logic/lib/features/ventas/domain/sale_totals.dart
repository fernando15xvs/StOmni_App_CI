enum SaleDiscountMode { percentage, fixedAmount }

/// Resultado puro de precios de una venta.
///
/// No conoce widgets, controladores de texto ni medios de pago. Puede ser
/// reutilizado por mobile, desktop, API tests o cualquier otra interfaz.
class SaleTotals {
  const SaleTotals({
    required this.subtotal,
    required this.discountInput,
    required this.discountMode,
    required this.discountAmount,
    required this.discountPercentage,
    required this.total,
  });

  final double subtotal;
  final double discountInput;
  final SaleDiscountMode discountMode;
  final double discountAmount;
  final double discountPercentage;
  final double total;

  bool get hasDiscount => discountAmount > 0;

  factory SaleTotals.calculate({
    required double subtotal,
    required double discountInput,
    required SaleDiscountMode discountMode,
  }) {
    final safeSubtotal = subtotal.isFinite ? subtotal : 0.0;
    final safeInput = discountInput.isFinite ? discountInput : 0.0;

    if (safeSubtotal <= 0 || safeInput <= 0) {
      return SaleTotals(
        subtotal: safeSubtotal,
        discountInput: safeInput,
        discountMode: discountMode,
        discountAmount: 0,
        discountPercentage: 0,
        total: safeSubtotal > 0 ? safeSubtotal : 0,
      );
    }

    final discountAmount = switch (discountMode) {
      SaleDiscountMode.percentage => safeSubtotal * (safeInput / 100),
      SaleDiscountMode.fixedAmount => safeInput,
    };

    final discountPercentage = switch (discountMode) {
      SaleDiscountMode.percentage => safeInput,
      SaleDiscountMode.fixedAmount => safeSubtotal == 0
          ? 0.0
          : (safeInput / safeSubtotal) * 100,
    };

    final rawTotal = safeSubtotal - discountAmount;

    return SaleTotals(
      subtotal: safeSubtotal,
      discountInput: safeInput,
      discountMode: discountMode,
      discountAmount: discountAmount,
      discountPercentage: discountPercentage,
      total: rawTotal > 0 ? rawTotal : 0,
    );
  }
}
