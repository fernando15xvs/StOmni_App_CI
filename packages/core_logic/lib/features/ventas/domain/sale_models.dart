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

  bool get usaEfectivo => pagos.any(
    (pago) => pago.metodo.trim().toLowerCase() == 'efectivo' && pago.monto > 0,
  );

}
