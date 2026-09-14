import '../data/pending_sale_mapper.dart';
import '../../../auth/providers/operation_authorizer_provider.dart';
import '../../../business/providers/business_profile_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/facturacion_service.dart';
import '../../../services/offline_service.dart';
import '../../../utils/app_time.dart';
import '../application/sale_processing_models.dart';
import '../application/venta_application_ports.dart';
import '../application/venta_submission_coordinator.dart';
import '../data/venta_context_repository.dart';
import '../data/ventas_repository.dart';
import '../domain/sale_models.dart';
import '../domain/fiscal_policy.dart';
import '../../facturacion/domain/peru_sunat_fiscal_policy.dart';
import '../usecases/procesar_venta_usecase.dart';

class _VentaContextRepositoryAdapter implements VentaContextGateway {
  const _VentaContextRepositoryAdapter(this._repository);

  final VentaContextRepository _repository;

  @override
  String? get currentAuthUserId => _repository.currentAuthUserId;

  @override
  Future<int?> resolverVendedorActivoId(int? vendedorId) =>
      _repository.resolverVendedorActivoId(vendedorId);

  @override
  Future<bool> cajaChicaAbierta() => _repository.cajaChicaAbierta();

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) => _repository.resolverCliente(
    ruc: ruc,
    nombre: nombre,
    direccion: direccion,
  );
}

class _VentaProcessingRepositoryAdapter implements VentaProcessingGateway {
  const _VentaProcessingRepositoryAdapter(this._repository);

  final VentasRepository _repository;

  @override
  Future<VentaProcessingResult> processSale(
    VentaProcessingRequest request,
  ) async {
    final rawResult = await _repository.processSaleRpc(
      requestId: request.requestId,
      clienteId: request.clienteId,
      total: request.total,
      fecha: AppTime.toIsoLima(request.fecha),
      esCredito: request.esCredito,
      montoAbono: request.montoAbono,
      detalles: request.detalles
          .map(
            (line) => <String, dynamic>{
              'producto_id': line.productId,
              'cantidad': line.quantity,
              'piezas_reales': line.storedBaseQuantity,
              'cantidad_base_comercial': line.baseQuantity,
              'stock_scale': line.storageScale,
              'precio_unitario': line.baseUnitPrice,
              'precio_unitario_comercial': line.commercialUnitPrice,
              'subtotal': line.subtotal,
              'almacen_id': line.warehouseId,
              'tipo_unidad': line.unitCode,
              'unidadLabel': line.baseUnitLabel,
              if (line.presentationRevision != null)
                'unit_profile_revision': line.presentationRevision,
              if (line.commercialUnitLabel != null)
                'commercial_unit_label': line.commercialUnitLabel,
              if (line.serialNumbers.isNotEmpty)
                'serial_numbers': List<String>.unmodifiable(line.serialNumbers),
            },
          )
          .toList(growable: false),
      pagos: request.pagos
          .map(
            (payment) => <String, dynamic>{
              'metodo': payment.metodo,
              'monto': payment.monto,
            },
          )
          .toList(growable: false),
      cotizacionId: request.cotizacionId,
      vendedorId: request.vendedorId,
      tipoComprobante: request.tipoComprobante,
      descuentoGlobalPorcentaje: request.descuentoGlobalPorcentaje,
      descuentoGlobalMonto: request.descuentoGlobalMonto,
      motivoDescuento: request.motivoDescuento,
      subtotalBruto: request.subtotalBruto,
      descuentoAutorizadoPor: request.descuentoAutorizadoPor,
    );

    final comprobanteId = rawResult['comprobante_id']?.toString().trim();
    return VentaProcessingResult(
      idempotent: rawResult['idempotent'] == true,
      comprobanteId: comprobanteId == null || comprobanteId.isEmpty
          ? null
          : comprobanteId,
    );
  }
}

final ventaConnectivityGatewayProvider = Provider<VentaConnectivityGateway>((ref) {
  throw StateError('VentaConnectivityGateway no fue configurado por el cliente.');
});

class _PendingSaleQueueAdapter implements PendingSaleQueueGateway {
  const _PendingSaleQueueAdapter();

  @override
  Future<void> enqueue(PendingSale sale) =>
      OfflineService.guardarVentaOffline(PendingSaleMapper.encode(sale));
}

class _ElectronicSaleDocumentAdapter implements ElectronicSaleDocumentGateway {
  const _ElectronicSaleDocumentAdapter();

  @override
  Future<ElectronicSaleDocumentResult> emitirComprobante(
    String comprobanteId,
  ) async {
    final rawResult = await FacturacionService.emitirComprobante(comprobanteId);
    return ElectronicSaleDocumentResult(
      estado: rawResult['estado']?.toString() ?? '',
      mensaje: rawResult['mensaje']?.toString(),
    );
  }
}

final ventaContextGatewayProvider = Provider<VentaContextGateway>((ref) {
  return _VentaContextRepositoryAdapter(
    ref.watch(ventaContextRepositoryProvider),
  );
});

final ventaProcessingGatewayProvider = Provider<VentaProcessingGateway>((ref) {
  return _VentaProcessingRepositoryAdapter(ref.watch(ventasRepositoryProvider));
});

final fiscalPolicyProvider = Provider<FiscalPolicy>(
  (ref) => const PeruSunatFiscalPolicy(),
);

final procesarVentaUseCaseProvider = Provider<ProcesarVentaUseCase>((ref) {
  return ProcesarVentaUseCase(
    authorizer: ref.watch(operationAuthorizerProvider),
    businessPolicy: ref.watch(businessSalePolicyProvider),
    context: ref.watch(ventaContextGatewayProvider),
    processing: ref.watch(ventaProcessingGatewayProvider),
    fiscalPolicy: ref.watch(fiscalPolicyProvider),
  );
});

final ventaSubmissionCoordinatorProvider = Provider<VentaSubmissionCoordinator>(
  (ref) {
    return VentaSubmissionCoordinator(
      procesarVenta: ref.watch(procesarVentaUseCaseProvider),
      context: ref.watch(ventaContextGatewayProvider),
      connectivity: ref.watch(ventaConnectivityGatewayProvider),
      pendingSales: const _PendingSaleQueueAdapter(),
      electronicDocuments: const _ElectronicSaleDocumentAdapter(),
    );
  },
);