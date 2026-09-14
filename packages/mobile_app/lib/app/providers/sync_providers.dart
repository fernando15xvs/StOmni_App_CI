import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final pendingSaleSyncAdapterProvider = Provider<PendingSaleSyncAdapter>((ref) {
  throw StateError('PendingSaleSyncAdapter no fue configurado.');
});

final inventorySyncAdapterProvider = Provider<InventorySyncAdapter>((ref) {
  throw StateError('InventorySyncAdapter no fue configurado.');
});

final pendingSalesRevisionProvider = StateProvider<int>((ref) => 0);

/// Una sola instancia coordina el botón manual, reconexión y reanudación.
final syncPendingOperationsProvider = Provider<SyncPendingOperationsUseCase>(
  (ref) => SyncPendingOperationsUseCase(_MobileSyncGateway(ref)),
);

class _MobileSyncGateway implements SyncPendingOperationsGateway {
  _MobileSyncGateway(this.ref);
  final Ref ref;

  @override
  bool get hasAuthenticatedSession =>
      ref.read(supabaseProvider).auth.currentUser != null;

  @override
  Future<int> pendingSalesCount() => OfflineService.cantidadVentasPendientes();

  @override
  Future<PendingSyncAuthorization> revalidateSession() async {
    final result = await ref
        .read(authControllerProvider.notifier)
        .revalidateCurrentSession();
    return switch (result) {
      AuthRevalidationResult.valid => PendingSyncAuthorization.valid,
      AuthRevalidationResult.unavailable => PendingSyncAuthorization.unavailable,
      AuthRevalidationResult.denied => PendingSyncAuthorization.denied,
    };
  }

  @override
  Future<int> synchronizePendingSales() async {
    final remaining = await OfflineService.sincronizarVentasPendientes(
      ref.read(pendingSaleSyncAdapterProvider),
    );
    return remaining.length;
  }

  @override
  Future<void> refreshInventory() async {
    ref.read(pendingSalesRevisionProvider.notifier).state++;
    await ref.read(inventorySyncAdapterProvider)
        .sincronizarTodo(propagarError: true);
  }
}
