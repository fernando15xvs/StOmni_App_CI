import '../../../database/tenant_pending_sale_queue.dart';
import '../application/venta_application_ports.dart';
import '../domain/sale_models.dart';
import 'pending_sale_mapper.dart';

/// I3 composition adapter for the existing VentaSubmissionCoordinator.
/// Only wiring from a server-validated, per-window selected tenant is safe:
/// the current single-company OfflineService remains the operational default.
///
/// No legacy ticket is imported and no electronic fiscal document is queued.
final class TenantPendingSaleQueueGateway implements PendingSaleQueueGateway {
  const TenantPendingSaleQueueGateway(this.queue);

  final TenantPendingSaleQueue queue;

  @override
  Future<void> enqueue(PendingSale sale) async {
    if (sale.authUserId != queue.scope.authUserId) {
      throw StateError('El ticket no pertenece al usuario autenticado.');
    }
    if (sale.tipoComprobante.toLowerCase() != 'ticket_interno') {
      throw StateError('Solo Ticket Interno admite cola offline.');
    }
    final payload = PendingSaleMapper.encode(sale);
    payload['organization_id'] = queue.scope.organizationId;
    await queue.saveTicket(payload);
  }
}
