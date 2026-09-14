import '../../features/ventas/domain/sale_models.dart';

/// Procesa un snapshot tipado; la serialización pertenece al almacén de cola.
abstract interface class PendingSaleSyncAdapter {
  Future<void> sincronizarVenta(PendingSale sale);
}

abstract interface class InventorySyncAdapter {
  Future<void> sincronizarProducto(int productoId);
  Future<void> sincronizarTodo({bool propagarError = false});
}
