import 'sale_cart.dart';

class SaleCustomer {
  const SaleCustomer({
    required this.ruc,
    required this.nombre,
    required this.direccion,
  });

  final String ruc;
  final String nombre;
  final String direccion;
}

class SalePayment {
  const SalePayment({required this.metodo, required this.monto});

  final String metodo;
  final double monto;
}

class SaleCreditInstallment {
  const SaleCreditInstallment({
    required this.number,
    required this.amount,
    required this.dueDate,
  });

  final int number;
  final double amount;
  final DateTime dueDate;
}

class SaleCreditTerms {
  SaleCreditTerms({required Iterable<SaleCreditInstallment> installments})
    : installments = List<SaleCreditInstallment>.unmodifiable(installments);

  factory SaleCreditTerms.single({
    required double amount,
    required DateTime dueDate,
  }) => SaleCreditTerms(
    installments: [
      SaleCreditInstallment(number: 1, amount: amount, dueDate: dueDate),
    ],
  );

  final List<SaleCreditInstallment> installments;

  double get total => installments.fold<double>(
    0,
    (sum, installment) => sum + installment.amount,
  );

  String? validate({
    required DateTime saleDate,
    required double amountDue,
  }) {
    if (installments.isEmpty) {
      return 'Agrega al menos una cuota para el saldo pendiente.';
    }
    if (!amountDue.isFinite || amountDue <= 0) {
      return 'El saldo pendiente debe ser mayor a S/ 0.00.';
    }

    final saleDay = DateTime(saleDate.year, saleDate.month, saleDate.day);
    var expectedNumber = 1;
    var sum = 0.0;

    for (final installment in installments) {
      if (installment.number != expectedNumber) {
        return 'Las cuotas deben estar numeradas consecutivamente desde 1.';
      }
      if (!installment.amount.isFinite || installment.amount <= 0) {
        return 'Cada cuota debe tener un importe mayor a S/ 0.00.';
      }
      final dueDay = DateTime(
        installment.dueDate.year,
        installment.dueDate.month,
        installment.dueDate.day,
      );
      if (!dueDay.isAfter(saleDay)) {
        return 'Cada cuota debe vencer después de la fecha de la venta.';
      }
      sum += installment.amount;
      expectedNumber++;
    }

    if ((sum - amountDue).abs() > 0.01) {
      return 'Las cuotas deben sumar exactamente el saldo pendiente.';
    }
    return null;
  }
}

/// Snapshot completo que permite reproducir un Ticket Interno offline sin
/// volver a consultar el estado visual del carrito.
class PendingSale {
  PendingSale({
    required this.requestId,
    required this.fecha,
    required this.esCredito,
    required this.totalAPagar,
    required this.montoAbono,
    required this.montoDeuda,
    required this.concepto,
    required this.tipoComprobante,
    required this.subtotalBruto,
    required this.descuentoGlobalPorcentaje,
    required this.descuentoGlobalMonto,
    required this.motivoDescuento,
    required this.cliente,
    required Iterable<SalePayment> pagos,
    required this.detalles,
    this.creditTerms,
    this.cotizacionId,
    this.vendedorId,
    this.authUserId,
    this.descuentoAutorizadoPor,
  }) : pagos = List<SalePayment>.unmodifiable(pagos);

  final String requestId;
  final String fecha;
  final bool esCredito;
  final double totalAPagar;
  final double montoAbono;
  final double montoDeuda;
  final String concepto;
  final int? cotizacionId;
  final int? vendedorId;

  /// `auth_id` de la sesión que originó la venta offline. Es nullable para
  /// mantener compatibilidad con registros creados antes de Fase 3.
  final String? authUserId;

  final String tipoComprobante;
  final double subtotalBruto;
  final double descuentoGlobalPorcentaje;
  final double descuentoGlobalMonto;
  final String motivoDescuento;
  final int? descuentoAutorizadoPor;
  final SaleCustomer cliente;
  final List<SalePayment> pagos;
  final SaleCart detalles;
  final SaleCreditTerms? creditTerms;

  bool get usaEfectivo => pagos.any(
    (pago) => pago.metodo.trim().toLowerCase() == 'efectivo' && pago.monto > 0,
  );
}
