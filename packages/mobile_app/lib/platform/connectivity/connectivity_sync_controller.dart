import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers/sync_providers.dart';

enum SyncResultType { idle, syncing, requireLogin, error, partial, success }

class ConnectivitySyncState {
  final SyncResultType type;
  final String? message;
  final int? syncedCount;
  final int? pendingCount;

  const ConnectivitySyncState({
    required this.type,
    this.message,
    this.syncedCount,
    this.pendingCount,
  });

  factory ConnectivitySyncState.idle() =>
      const ConnectivitySyncState(type: SyncResultType.idle);

  factory ConnectivitySyncState.syncing() =>
      const ConnectivitySyncState(type: SyncResultType.syncing);

  factory ConnectivitySyncState.requireLogin() =>
      const ConnectivitySyncState(type: SyncResultType.requireLogin);

  factory ConnectivitySyncState.error(String message) =>
      ConnectivitySyncState(type: SyncResultType.error, message: message);

  factory ConnectivitySyncState.partial({
    required String message,
    required int syncedCount,
    required int pendingCount,
  }) => ConnectivitySyncState(
    type: SyncResultType.partial,
    message: message,
    syncedCount: syncedCount,
    pendingCount: pendingCount,
  );

  factory ConnectivitySyncState.success(
    int syncedCount,
    int pendingCount, {
    String? message,
  }) => ConnectivitySyncState(
    type: SyncResultType.success,
    syncedCount: syncedCount,
    pendingCount: pendingCount,
    message: message,
  );
}

/// Adaptador móvil: escucha el estado de red y traduce el resultado del caso
/// de uso a estado de presentación. Las reglas de coordinación viven en Core.
class ConnectivitySyncController extends StateNotifier<ConnectivitySyncState> {
  final Connectivity _connectivity;
  final SyncPendingOperationsUseCase _syncPendingOperations;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool? _wasOffline;
  bool _isDisposed = false;

  ConnectivitySyncController(
    Ref ref, {
    Connectivity? connectivity,
    SyncPendingOperationsUseCase? syncPendingOperations,
  }) : _connectivity = connectivity ?? Connectivity(),
       _syncPendingOperations =
           syncPendingOperations ?? ref.read(syncPendingOperationsProvider),
       super(ConnectivitySyncState.idle()) {
    _subscription = _connectivity.onConnectivityChanged.listen(
      _handleConnectivityChanged,
    );
    unawaited(_primeConnectivityState());
  }

  Future<void> _primeConnectivityState() async {
    try {
      final result = await _connectivity.checkConnectivity();
      if (_isDisposed || _wasOffline != null) return;

      final offline = _isOffline(result);
      _wasOffline = offline;

      if (!offline) {
        unawaited(syncPendingSales().then<void>((_) {}));
      }
    } catch (_) {}
  }

  void _handleConnectivityChanged(List<ConnectivityResult> result) {
    final offline = _isOffline(result);
    final previousOffline = _wasOffline;
    _wasOffline = offline;

    if (!offline && previousOffline != false) {
      unawaited(syncPendingSales().then<void>((_) {}));
    }
  }

  bool _isOffline(List<ConnectivityResult> result) {
    return result.isEmpty ||
        result.every((item) => item == ConnectivityResult.none);
  }

  Future<SyncPendingOperationsResult?> syncPendingSales() async {
    if (_isDisposed || state.type == SyncResultType.syncing) return null;

    try {
      final connectivity = await _connectivity.checkConnectivity();
      if (_isDisposed || _isOffline(connectivity)) return null;
    } catch (_) {
      return null;
    }

    state = ConnectivitySyncState.syncing();
    try {
      final result = await _syncPendingOperations.execute();
      if (_isDisposed) return null;
      _applyResult(result);
      return result;
    } catch (_) {
      if (_isDisposed) return null;
      state = ConnectivitySyncState.error(_pendingSyncMessage);
      return null;
    }
  }

  void _applyResult(SyncPendingOperationsResult result) {
    switch (result.outcome) {
      case PendingOperationsSyncOutcome.idle:
        state = ConnectivitySyncState.idle();
      case PendingOperationsSyncOutcome.authorizationUnavailable:
        state = ConnectivitySyncState.error(_authorizationMessage);
      case PendingOperationsSyncOutcome.requireLogin:
        state = ConnectivitySyncState.requireLogin();
      case PendingOperationsSyncOutcome.partial:
        state = ConnectivitySyncState.partial(
          message: _pendingSyncMessage,
          syncedCount: result.syncedCount,
          pendingCount: result.pendingCount,
        );
      case PendingOperationsSyncOutcome.success:
        state = ConnectivitySyncState.success(
          result.syncedCount,
          result.pendingCount,
          message: result.inventoryRefreshPending
              ? 'Las ventas se guardaron. Falta actualizar la vista de inventario.'
              : null,
        );
    }
  }

  static const _authorizationMessage =
      'La conexión volvió, pero todavía no pudimos verificar tu cuenta. '
      'Tus ventas pendientes siguen guardadas y se sincronizarán cuando '
      'la conexión sea estable.';

  static const _pendingSyncMessage =
      'No pudimos sincronizar todavía. Tus ventas pendientes siguen '
      'guardadas de forma segura para intentarlo nuevamente.';

  @override
  void dispose() {
    _isDisposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}

final connectivitySyncControllerProvider =
    StateNotifierProvider<ConnectivitySyncController, ConnectivitySyncState>(
      (ref) => ConnectivitySyncController(ref),
    );
