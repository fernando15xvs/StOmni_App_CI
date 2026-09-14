import '../../../utils/app_time.dart';
import '../../../auth/domain/app_permission.dart';
import '../domain/sale_cart.dart';
import '../domain/sale_models.dart';
import '../usecases/procesar_venta_usecase.dart';
import 'procesar_venta_command.dart';
import 'sale_processing_models.dart';
import 'venta_application_ports.dart';

enum VentaSubmissionTone { success, warning, error }

class VentaSubmissionRequest {
  VentaSubmissionRequest({
    required this.requestId,
    required this.fecha,
    required this.esCredito,
    required this.totalAPagar,
    required this.montoAbono,
    required this.concepto,
    required this.tipoComprobante,
    required this.subtotalBruto,
    required this.descuentoGlobalPorcentaje,
    required this.descuentoGlobalMonto,
    required this.motivoDescuento,
    required this.cliente,
    required Iterable<SalePayment> pagos,
    required this.carrito,
    this.cotizacionId,
    this.vendedorId,
    this.descuentoAutorizadoPor,
  }) : pagos = List<SalePayment>.unmodifiable(pagos);

  final String requestId;
  final DateTime fecha;
  final bool esCredito;
  final double totalAPagar;
  final double montoAbono;
  final String concepto;
  final int? cotizacionId;
  final int? vendedorId;
  final String tipoComprobante;
  final double subtotalBruto;
  final double descuentoGlobalPorcentaje;
  final double descuentoGlobalMonto;
  final String motivoDescuento;
  final int? descuentoAutorizadoPor;
  final SaleCustomer cliente;
  final List<SalePayment> pagos;
  final SaleCart carrito;

  String get tipoComprobanteNormalizado => tipoComprobante.trim().toLowerCase();
  bool get usaEfectivo => pagos.any(
    (pago) => pago.metodo.trim().toLowerCase() == 'efectivo' && pago.monto > 0,
  );

  ProcesarVentaCommand toProcessingCommand() => ProcesarVentaCommand(
    requestId: requestId,
    customer: cliente,
    esCredito: esCredito,
    totalAPagar: totalAPagar,
    montoAbono: montoAbono,
    payments: pagos,
    cart: carrito,
    cotizacionId: cotizacionId,
    fecha: fecha,
    vendedorId: vendedorId,
    tipoComprobante: tipoComprobanteNormalizado,
    descuentoGlobalPorcentaje: descuentoGlobalPorcentaje,
    descuentoGlobalMonto: descuentoGlobalMonto,
    motivoDescuento: motivoDescuento,
    subtotalBruto: subtotalBruto,
    descuentoAutorizadoPor: descuentoAutorizadoPor,
  );

  PendingSale toPendingSale({String? authUserId}) => PendingSale(
    requestId: requestId,
    fecha: AppTime.toIsoLima(fecha),
    esCredito: esCredito,
    totalAPagar: totalAPagar,
    montoAbono: montoAbono,
    montoDeuda: totalAPagar - montoAbono,
    concepto: concepto,
    cotizacionId: cotizacionId,
    vendedorId: vendedorId,
    authUserId: authUserId,
    tipoComprobante: tipoComprobanteNormalizado,
    subtotalBruto: subtotalBruto,
    descuentoGlobalPorcentaje: descuentoGlobalPorcentaje,
    descuentoGlobalMonto: descuentoGlobalMonto,
    motivoDescuento: motivoDescuento,
    descuentoAutorizadoPor: descuentoAutorizadoPor,
    cliente: cliente,
    pagos: pagos,
    detalles: carrito,
  );
}

class VentaSubmissionOutcome {
  const VentaSubmissionOutcome({
    required this.message,
    required this.tone,
    this.offlineQueued = false,
    this.result,
  });
  final String message;
  final VentaSubmissionTone tone;
  final bool offlineQueued;
  final VentaProcessingResult? result;
}

class VentaSubmissionException implements Exception {
  const VentaSubmissionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VentaSubmissionCoordinator {
  const VentaSubmissionCoordinator({
    required ProcesarVentaUseCase procesarVenta,
    required VentaContextGateway context,
    required VentaConnectivityGateway connectivity,
    required PendingSaleQueueGateway pendingSales,
    required ElectronicSaleDocumentGateway electronicDocuments,
  }) : _procesarVenta = procesarVenta,
       _context = context,
       _connectivity = connectivity,
       _pendingSales = pendingSales,
       _electronicDocuments = electronicDocuments;

  final ProcesarVentaUseCase _procesarVenta;
  final VentaContextGateway _context;
  final VentaConnectivityGateway _connectivity;
  final PendingSaleQueueGateway _pendingSales;
  final ElectronicSaleDocumentGateway _electronicDocuments;

  Future<VentaSubmissionOutcome> submit(VentaSubmissionRequest request) async {
    final document = _procesarVenta.fiscalPolicy.documentFor(request.tipoComprobanteNormalizado);
    if (document == null) {
      throw const VentaSubmissionException(
        'El tipo de comprobante no es válido. No se procesó la venta.',
      );
    }

    _procesarVenta.validateCommand(request.toProcessingCommand());

    if (!await _connectivity.hasConnection()) {
      if (!document.allowsOffline) {
        throw const VentaSubmissionException(
          'Este comprobante requiere conexión antes de procesar la venta.',
        );
      }
      final authUserId = _context.currentAuthUserId?.trim();
      if (authUserId == null || authUserId.isEmpty) {
        throw const VentaSubmissionException(
          'No se pudo identificar la sesión que origina la venta offline. Vuelve a iniciar sesión antes de registrar el Ticket Interno.',
        );
      }
      final authorizedUser = await _procesarVenta.authorizer.require({
        AppPermission.salesCreate,
        if (request.descuentoGlobalMonto > 0) AppPermission.salesDiscount,
      }, allowOffline: true);
      await _procesarVenta.businessPolicy.validate(
        isCredit: request.esCredito,
        requiresElectronicEmission: document.requiresElectronicEmission,
        allowOffline: true,
      );
      if (authorizedUser != authUserId || _context.currentAuthUserId != authUserId) {
        throw const VentaSubmissionException('La sesión cambió antes de guardar la venta offline.');
      }
      await _pendingSales.enqueue(request.toPendingSale(authUserId: authUserId));
      return const VentaSubmissionOutcome(
        message: 'Sin conexión: la venta quedó guardada en este dispositivo.',
        tone: VentaSubmissionTone.success,
        offlineQueued: true,
      );
    }

    if (request.usaEfectivo) {
      try {
        if (!await _context.cajaChicaAbierta()) {
          throw const VentaSubmissionException(
            'Debes abrir la Caja Chica antes de procesar pagos en efectivo.',
          );
        }
      } on VentaSubmissionException {
        rethrow;
      } catch (_) {
        throw const VentaSubmissionException(
          'No se pudo verificar el estado de Caja Chica. Por seguridad, el pago en efectivo no fue procesado.',
        );
      }
    }

    final resultado = await _procesarVenta.ejecutarCommand(request.toProcessingCommand());
    final idempotente = resultado.idempotent;
    ElectronicSaleDocumentResult? resultadoEmision;
    String? errorEmision;
    final comprobanteId = resultado.comprobanteId;

    if (document.requiresElectronicEmission && comprobanteId != null && comprobanteId.isNotEmpty) {
      try {
        resultadoEmision = await _electronicDocuments.emitirComprobante(comprobanteId);
      } catch (error) {
        errorEmision = error.toString();
      }
    }

    final estadoEmision = resultadoEmision?.estadoNormalizado;
    if (idempotente && !document.requiresElectronicEmission) {
      return VentaSubmissionOutcome(
        message: 'La venta ya había sido registrada. No se duplicó el stock ni el comprobante.',
        tone: VentaSubmissionTone.success,
        result: resultado,
      );
    }
    if (!document.requiresElectronicEmission) {
      return VentaSubmissionOutcome(
        message: '¡Venta procesada correctamente!',
        tone: VentaSubmissionTone.success,
        result: resultado,
      );
    }
    if (estadoEmision == 'aceptado') {
      return VentaSubmissionOutcome(
        message: 'Comprobante aceptado correctamente.',
        tone: VentaSubmissionTone.success,
        result: resultado,
      );
    }
    if (estadoEmision == 'rechazado') {
      return VentaSubmissionOutcome(
        message: resultadoEmision?.mensaje ??
            'Venta registrada, pero el comprobante fue rechazado.',
        tone: VentaSubmissionTone.error,
        result: resultado,
      );
    }
    return VentaSubmissionOutcome(
      message: errorEmision == null
          ? 'Venta registrada. El comprobante quedó pendiente de revisión y reintento manual.'
          : 'Venta registrada. No se pudo completar el envío; revisa el comprobante y reinténtalo manualmente.',
      tone: VentaSubmissionTone.warning,
      result: resultado,
    );
  }
}
