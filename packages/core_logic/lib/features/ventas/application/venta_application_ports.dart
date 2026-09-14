import '../domain/sale_models.dart';
import 'sale_processing_models.dart';

/// Puerto de aplicación para resolver el contexto necesario de una venta.
///
/// Las implementaciones pueden usar Supabase, almacenamiento local u otra
/// infraestructura, pero los casos de uso no deben conocer esos detalles.
abstract interface class VentaContextGateway {
  String? get currentAuthUserId;

  Future<int?> resolverVendedorActivoId(int? vendedorId);

  Future<bool> cajaChicaAbierta();

  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  });
}

/// Puerto tipado de persistencia para la operación transaccional de venta.
abstract interface class VentaProcessingGateway {
  Future<VentaProcessingResult> processSale(VentaProcessingRequest request);
}

/// Puerto para consultar conectividad sin acoplar application a plugins.
abstract interface class VentaConnectivityGateway {
  Future<bool> hasConnection();
}

/// Puerto para persistir ventas pendientes cuando no hay conexión.
abstract interface class PendingSaleQueueGateway {
  Future<void> enqueue(PendingSale sale);
}

/// Puerto tipado para emitir el documento electrónico asociado a una venta.
abstract interface class ElectronicSaleDocumentGateway {
  Future<ElectronicSaleDocumentResult> emitirComprobante(String comprobanteId);
}
