import '../../../utils/app_time.dart';
import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../business/application/business_sale_policy.dart';
import '../application/validate_sale_use_case.dart';
import '../application/procesar_venta_command.dart';
import '../application/sale_processing_models.dart';
import '../application/venta_application_ports.dart';
import '../domain/sale_models.dart';
import '../domain/fiscal_policy.dart';

class ProcesarVentaUseCase {
  ProcesarVentaUseCase({
    required VentaContextGateway context,
    required VentaProcessingGateway processing,
    required this.fiscalPolicy,
    required this.authorizer,
    required this.businessPolicy,
    DateTime Function()? now,
  }) : _context = context,
       _processing = processing,
       _now = now ?? AppTime.now;

  final VentaContextGateway _context;
  final VentaProcessingGateway _processing;
  final FiscalPolicy fiscalPolicy;
  final OperationAuthorizer authorizer;
  final BusinessSalePolicy businessPolicy;
  final DateTime Function() _now;

  ValidatedSale validateCommand(ProcesarVentaCommand command) {
    final validated = const ValidateSaleUseCase().execute(command);
    final document = fiscalPolicy.documentFor(command.tipoComprobanteNormalizado);
    if (document == null) {
      throw StateError('El tipo de comprobante no está habilitado.');
    }
    if (document.requiresElectronicEmission) {
      final missingFiscalUnit = validated.lines.any(
        (line) =>
            line.presentationRevision != null && !line.hasValidFiscalUnitCode,
      );
      if (missingFiscalUnit) {
        throw StateError(
          'Configura un código fiscal de unidad válido en cada presentación '
          'antes de emitir boleta o factura electrónica.',
        );
      }
    }
    final fiscalError = fiscalPolicy.validate(command.fiscalDraft, now: _now());
    if (fiscalError != null) throw StateError(fiscalError);
    return validated;
  }

  /// Entrada principal tipada del caso de uso.
  Future<VentaProcessingResult> ejecutarCommand(
    ProcesarVentaCommand command,
  ) async {
    final validated = validateCommand(command);
    final tipoComprobanteNormalizado = command.tipoComprobanteNormalizado;
    final expectedUser = command.expectedAuthUserId ?? _context.currentAuthUserId;
    if (expectedUser == null || expectedUser.trim().isEmpty ||
        expectedUser != _context.currentAuthUserId) {
      throw StateError('La sesión cambió antes de procesar la venta.');
    }

    final authorizedUser = await authorizer.require({
      AppPermission.salesCreate,
      if (command.descuentoGlobalMonto > 0) AppPermission.salesDiscount,
    });
    await businessPolicy.validate(
      isCredit: command.esCredito,
      requiresElectronicEmission: fiscalPolicy.documentFor(tipoComprobanteNormalizado)!
          .requiresElectronicEmission,
    );
    if (authorizedUser != expectedUser || expectedUser != _context.currentAuthUserId) {
      throw StateError('La sesión cambió al autorizar la venta.');
    }

    final vendedorIdDb = await _context.resolverVendedorActivoId(
      command.vendedorId,
    );
    if (expectedUser != _context.currentAuthUserId) {
      throw StateError('La sesión cambió al resolver el vendedor.');
    }
    final clienteId = await _context.resolverCliente(
      ruc: command.customer.ruc,
      nombre: command.customer.nombre,
      direccion: command.customer.direccion,
    );

    if (expectedUser != _context.currentAuthUserId) {
      throw StateError('La sesión cambió durante el procesamiento de la venta.');
    }

    return _processing.processSale(
      VentaProcessingRequest(
        requestId: command.requestId,
        clienteId: clienteId,
        total: command.totalAPagar,
        fecha: command.fecha,
        esCredito: command.esCredito,
        montoAbono: command.montoAbono,
        detalles: validated.lines,
        pagos: List<SalePayment>.unmodifiable(command.payments),
        cotizacionId: command.cotizacionId,
        vendedorId: vendedorIdDb,
        tipoComprobante: tipoComprobanteNormalizado,
        descuentoGlobalPorcentaje: command.descuentoGlobalPorcentaje,
        descuentoGlobalMonto: command.descuentoGlobalMonto,
        motivoDescuento: command.motivoDescuento,
        subtotalBruto: validated.subtotal,
        descuentoAutorizadoPor: command.descuentoAutorizadoPor,
      ),
    );
  }

}
