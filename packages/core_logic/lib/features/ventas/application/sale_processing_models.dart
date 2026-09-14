import '../domain/sale_models.dart';

/// Línea de venta validada por aplicación y lista para persistencia.
class SaleProcessingLine {
  const SaleProcessingLine({
    required this.productId,
    required this.warehouseId,
    required this.quantity,
    required this.baseQuantity,
    required this.storedBaseQuantity,
    required this.storageScale,
    required this.unitCode,
    required this.baseUnitLabel,
    required this.commercialUnitPrice,
    required this.baseUnitPrice,
    required this.subtotal,
    this.presentationRevision,
    this.commercialUnitLabel,
    this.fiscalUnitCode,
    this.serialNumbers = const <String>[],
  });

  final int productId;
  final int warehouseId;
  final double quantity;
  final double baseQuantity;
  final int storedBaseQuantity;
  final int storageScale;
  final String unitCode;
  final String baseUnitLabel;
  final double commercialUnitPrice;
  final double baseUnitPrice;
  final double subtotal;
  final int? presentationRevision;
  final String? commercialUnitLabel;
  final String? fiscalUnitCode;
  final List<String> serialNumbers;

  bool get usesScaledStorage => storageScale > 1;

  bool get hasValidFiscalUnitCode {
    final code = fiscalUnitCode?.trim().toUpperCase();
    return code != null && RegExp(r'^[A-Z0-9]{1,6}$').hasMatch(code);
  }
}

class VentaProcessingRequest {
  const VentaProcessingRequest({
    required this.requestId,
    required this.clienteId,
    required this.total,
    required this.fecha,
    required this.esCredito,
    required this.montoAbono,
    required this.detalles,
    required this.pagos,
    this.cotizacionId,
    this.vendedorId,
    this.tipoComprobante = 'ticket_interno',
    this.descuentoGlobalPorcentaje = 0,
    this.descuentoGlobalMonto = 0,
    this.motivoDescuento,
    this.subtotalBruto = 0,
    this.descuentoAutorizadoPor,
  });

  final String requestId;
  final int clienteId;
  final double total;
  final DateTime fecha;
  final bool esCredito;
  final double montoAbono;
  final List<SaleProcessingLine> detalles;
  final List<SalePayment> pagos;
  final int? cotizacionId;
  final int? vendedorId;
  final String tipoComprobante;
  final double descuentoGlobalPorcentaje;
  final double descuentoGlobalMonto;
  final String? motivoDescuento;
  final double subtotalBruto;
  final int? descuentoAutorizadoPor;
}

class VentaProcessingResult {
  const VentaProcessingResult({
    required this.idempotent,
    this.comprobanteId,
  });

  final bool idempotent;
  final String? comprobanteId;
}

class ElectronicSaleDocumentResult {
  const ElectronicSaleDocumentResult({
    required this.estado,
    this.mensaje,
  });

  final String estado;
  final String? mensaje;

  String get estadoNormalizado => estado.trim().toLowerCase();
}
