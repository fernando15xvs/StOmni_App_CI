import '../domain/sale_cart.dart';
import '../domain/sale_models.dart';
import '../domain/fiscal_policy.dart';

/// Entrada tipada del caso de uso que persiste una venta.
///
/// Agrupa la información que antes viajaba como una lista extensa de
/// parámetros y mantiene el caso de uso independiente de widgets/controladores.
class ProcesarVentaCommand {
  ProcesarVentaCommand({
    required this.requestId,
    required this.customer,
    required this.esCredito,
    required this.totalAPagar,
    required this.montoAbono,
    required Iterable<SalePayment> payments,
    required this.cart,
    required this.fecha,
    this.cotizacionId,
    this.vendedorId,
    this.tipoComprobante = 'ticket_interno',
    this.descuentoGlobalPorcentaje = 0,
    this.descuentoGlobalMonto = 0,
    this.motivoDescuento,
    this.subtotalBruto = 0,
    this.descuentoAutorizadoPor,
    this.expectedAuthUserId,
  }) : payments = List<SalePayment>.unmodifiable(payments);

  final String requestId;
  final SaleCustomer customer;
  final bool esCredito;
  final double totalAPagar;
  final double montoAbono;
  final List<SalePayment> payments;
  final SaleCart cart;
  final int? cotizacionId;
  final DateTime fecha;
  final int? vendedorId;
  final String tipoComprobante;
  final double descuentoGlobalPorcentaje;
  final double descuentoGlobalMonto;
  final String? motivoDescuento;
  final double subtotalBruto;
  final int? descuentoAutorizadoPor;
  final String? expectedAuthUserId;

  FiscalSaleDraft get fiscalDraft => FiscalSaleDraft(
    documentCode: tipoComprobanteNormalizado,
    date: fecha,
    isCredit: esCredito,
    total: totalAPagar,
    customer: customer,
  );

  String get tipoComprobanteNormalizado {
    final normalized = tipoComprobante.trim().toLowerCase();
    return normalized == 'ticket' ? 'ticket_interno' : normalized;
  }

  factory ProcesarVentaCommand.fromPendingSale(
    PendingSale pending, {
    required DateTime fecha,
  }) {
    return ProcesarVentaCommand(
      requestId: pending.requestId,
      customer: pending.cliente,
      esCredito: pending.esCredito,
      totalAPagar: pending.totalAPagar,
      montoAbono: pending.montoAbono,
      payments: pending.pagos,
      cart: pending.detalles,
      cotizacionId: pending.cotizacionId,
      fecha: fecha,
      vendedorId: pending.vendedorId,
      tipoComprobante: pending.tipoComprobante,
      descuentoGlobalPorcentaje: pending.descuentoGlobalPorcentaje,
      descuentoGlobalMonto: pending.descuentoGlobalMonto,
      motivoDescuento: pending.motivoDescuento,
      subtotalBruto: pending.subtotalBruto,
      descuentoAutorizadoPor: pending.descuentoAutorizadoPor,
      expectedAuthUserId: pending.authUserId,
    );
  }
}
