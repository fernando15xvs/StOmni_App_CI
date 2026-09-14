enum PendingSyncAuthorization { valid, unavailable, denied }

enum PendingOperationsSyncOutcome {
  idle,
  authorizationUnavailable,
  requireLogin,
  partial,
  success,
}

class SyncPendingOperationsResult {
  final PendingOperationsSyncOutcome outcome;
  final int syncedCount;
  final int pendingCount;
  final bool inventoryRefreshPending;

  const SyncPendingOperationsResult.idle()
    : outcome = PendingOperationsSyncOutcome.idle,
      syncedCount = 0,
      pendingCount = 0,
      inventoryRefreshPending = false;

  const SyncPendingOperationsResult.authorizationUnavailable()
    : outcome = PendingOperationsSyncOutcome.authorizationUnavailable,
      syncedCount = 0,
      pendingCount = 0,
      inventoryRefreshPending = false;

  const SyncPendingOperationsResult.requireLogin()
    : outcome = PendingOperationsSyncOutcome.requireLogin,
      syncedCount = 0,
      pendingCount = 0,
      inventoryRefreshPending = false;

  const SyncPendingOperationsResult.partial({
    required this.syncedCount,
    required this.pendingCount,
    this.inventoryRefreshPending = false,
  }) : outcome = PendingOperationsSyncOutcome.partial;

  const SyncPendingOperationsResult.success({
    required this.syncedCount,
    this.pendingCount = 0,
    this.inventoryRefreshPending = false,
  }) : outcome = PendingOperationsSyncOutcome.success;
}

/// Puerto que adapta autenticación, cola durable e inventario al motor de sync.
///
/// Sus implementaciones pueden usar Riverpod, Supabase, SQLite o cualquier
/// tecnología de plataforma. El caso de uso solo conoce este contrato.
abstract interface class SyncPendingOperationsGateway {
  bool get hasAuthenticatedSession;

  Future<PendingSyncAuthorization> revalidateSession();

  Future<int> pendingSalesCount();

  /// Sincroniza la cola y devuelve cuántas ventas siguen pendientes.
  Future<int> synchronizePendingSales();

  Future<void> refreshInventory();
}

/// Coordina la recuperación de operaciones pendientes sin depender de UI,
/// conectividad, Riverpod ni Supabase.
class SyncPendingOperationsUseCase {
  final SyncPendingOperationsGateway gateway;
  Future<SyncPendingOperationsResult>? _inFlight;

  SyncPendingOperationsUseCase(this.gateway);

  Future<SyncPendingOperationsResult> execute() {
    final active = _inFlight;
    if (active != null) return active;
    final future = _execute();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<SyncPendingOperationsResult> _execute() async {
    if (!gateway.hasAuthenticatedSession) {
      return const SyncPendingOperationsResult.idle();
    }

    final authorization = await gateway.revalidateSession();
    switch (authorization) {
      case PendingSyncAuthorization.denied:
        return const SyncPendingOperationsResult.requireLogin();
      case PendingSyncAuthorization.unavailable:
        return const SyncPendingOperationsResult.authorizationUnavailable();
      case PendingSyncAuthorization.valid:
        break;
    }

    final queuedCount = await gateway.pendingSalesCount();
    if (queuedCount <= 0) {
      return const SyncPendingOperationsResult.idle();
    }

    final remaining = await gateway.synchronizePendingSales();
    final pendingCount = remaining < 0 ? 0 : remaining;
    final syncedCount = queuedCount > pendingCount
        ? queuedCount - pendingCount
        : 0;

    var inventoryRefreshPending = false;
    if (syncedCount > 0) {
      try {
        await gateway.refreshInventory();
      } catch (_) {
        // Las ventas ya confirmadas no se vuelven a encolar por un fallo de UI/cache.
        inventoryRefreshPending = true;
      }
    }

    if (pendingCount == 0) {
      return SyncPendingOperationsResult.success(
        syncedCount: syncedCount,
        inventoryRefreshPending: inventoryRefreshPending,
      );
    }

    return SyncPendingOperationsResult.partial(
      syncedCount: syncedCount,
      pendingCount: pendingCount,
      inventoryRefreshPending: inventoryRefreshPending,
    );
  }
}
