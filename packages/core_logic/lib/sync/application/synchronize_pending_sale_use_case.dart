import '../../features/ventas/application/procesar_venta_command.dart';
import '../../features/ventas/application/venta_application_ports.dart';
import '../../features/ventas/domain/pending_sale_session_policy.dart';
import '../../features/ventas/domain/sale_models.dart';
import '../../features/ventas/usecases/procesar_venta_usecase.dart';
import 'sync_ports.dart';

/// Reutiliza las mismas reglas de sesión, caja y venta en cualquier cliente.
class SynchronizePendingSaleUseCase implements PendingSaleSyncAdapter {
  const SynchronizePendingSaleUseCase({
    required this.context,
    required this.processSale,
  });

  final VentaContextGateway context;
  final ProcesarVentaUseCase processSale;

  @override
  Future<void> sincronizarVenta(PendingSale sale) async {
    final currentUser = context.currentAuthUserId?.trim();
    if (currentUser == null || currentUser.isEmpty ||
        !PendingSaleSessionPolicy.puedeSincronizar(
          authUserIdOrigen: sale.authUserId,
          authUserIdActual: currentUser,
        )) {
      throw StateError(
        'La venta pendiente pertenece a otra sesión. '
        'Inicia sesión con el usuario que la creó para sincronizarla.',
      );
    }
    if (sale.tipoComprobante.trim().toLowerCase() != 'ticket_interno') {
      throw StateError('La cola offline acepta únicamente Ticket Interno.');
    }
    final date = DateTime.tryParse(sale.fecha);
    if (date == null) {
      throw StateError('La venta pendiente no tiene una fecha válida.');
    }
    if (sale.usaEfectivo) {
      bool cashboxOpen;
      try {
        cashboxOpen = await context.cajaChicaAbierta();
      } catch (_) {
        throw StateError(
          'No se pudo verificar el estado de Caja Chica. '
          'La venta pendiente con efectivo no fue sincronizada.',
        );
      }
      if (!cashboxOpen) {
        throw StateError(
          'Debes abrir la Caja Chica antes de sincronizar esta venta '
          'pendiente con efectivo.',
        );
      }
    }
    if (context.currentAuthUserId?.trim() != currentUser) {
      throw StateError('La sesión cambió durante la sincronización.');
    }
    await processSale.ejecutarCommand(
      ProcesarVentaCommand.fromPendingSale(sale, fecha: date),
    );
  }
}
