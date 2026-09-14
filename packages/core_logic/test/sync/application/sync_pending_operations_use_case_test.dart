import 'dart:async';

import 'package:core_logic/sync/application/sync_pending_operations_use_case.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('revalida antes de leer y procesar la cola', () async {
    final gateway = _FakeGateway(
      queuedCount: 3,
      remainingCount: 0,
    );

    final result = await SyncPendingOperationsUseCase(gateway).execute();

    expect(result.outcome, PendingOperationsSyncOutcome.success);
    expect(result.syncedCount, 3);
    expect(result.pendingCount, 0);
    expect(
      gateway.calls,
      ['revalidate', 'count', 'synchronize', 'refreshInventory'],
    );
  });

  test('autorización denegada no toca la cola y requiere login', () async {
    final gateway = _FakeGateway(
      authorization: PendingSyncAuthorization.denied,
    );

    final result = await SyncPendingOperationsUseCase(gateway).execute();

    expect(result.outcome, PendingOperationsSyncOutcome.requireLogin);
    expect(gateway.calls, ['revalidate']);
  });

  test('validación no disponible conserva intacta la cola', () async {
    final gateway = _FakeGateway(
      authorization: PendingSyncAuthorization.unavailable,
    );

    final result = await SyncPendingOperationsUseCase(gateway).execute();

    expect(
      result.outcome,
      PendingOperationsSyncOutcome.authorizationUnavailable,
    );
    expect(gateway.calls, ['revalidate']);
  });

  test('sincronización parcial reporta cantidades y refresca inventario', () async {
    final gateway = _FakeGateway(
      queuedCount: 5,
      remainingCount: 2,
    );

    final result = await SyncPendingOperationsUseCase(gateway).execute();

    expect(result.outcome, PendingOperationsSyncOutcome.partial);
    expect(result.syncedCount, 3);
    expect(result.pendingCount, 2);
    expect(gateway.refreshCount, 1);
  });

  test('sin sesión autenticada no revalida ni toca la cola', () async {
    final gateway = _FakeGateway(hasAuthenticatedSession: false);

    final result = await SyncPendingOperationsUseCase(gateway).execute();

    expect(result.outcome, PendingOperationsSyncOutcome.idle);
    expect(gateway.calls, isEmpty);
  });

  test('reconexión y sincronización manual comparten una ejecución', () async {
    final gate = Completer<void>();
    final gateway = _FakeGateway(queuedCount: 2, syncGate: gate.future);
    final useCase = SyncPendingOperationsUseCase(gateway);
    final first = useCase.execute();
    final second = useCase.execute();
    gate.complete();

    final results = await Future.wait([first, second]);
    expect(results.map((result) => result.syncedCount), [2, 2]);
    expect(gateway.calls.where((call) => call == 'synchronize'), hasLength(1));
    expect(gateway.refreshCount, 1);
  });

  test('fallo de cache no convierte ventas confirmadas en pendientes', () async {
    final gateway = _FakeGateway(queuedCount: 2, failRefresh: true);
    final result = await SyncPendingOperationsUseCase(gateway).execute();
    expect(result.outcome, PendingOperationsSyncOutcome.success);
    expect(result.syncedCount, 2);
    expect(result.pendingCount, 0);
    expect(result.inventoryRefreshPending, isTrue);
  });

  test('un fallo libera single-flight para un nuevo intento', () async {
    final gateway = _FakeGateway(queuedCount: 1, failSync: true);
    final useCase = SyncPendingOperationsUseCase(gateway);
    await expectLater(useCase.execute(), throwsStateError);
    gateway.failSync = false;
    final result = await useCase.execute();
    expect(result.outcome, PendingOperationsSyncOutcome.success);
    expect(gateway.calls.where((call) => call == 'synchronize'), hasLength(2));
  });
}

class _FakeGateway implements SyncPendingOperationsGateway {
  _FakeGateway({
    this.hasAuthenticatedSession = true,
    this.authorization = PendingSyncAuthorization.valid,
    this.queuedCount = 0,
    this.remainingCount = 0,
    this.syncGate,
    this.failRefresh = false,
    this.failSync = false,
  });

  @override
  final bool hasAuthenticatedSession;
  final PendingSyncAuthorization authorization;
  final int queuedCount;
  final int remainingCount;
  final Future<void>? syncGate;
  final bool failRefresh;
  bool failSync;
  final List<String> calls = [];
  int refreshCount = 0;

  @override
  Future<int> pendingSalesCount() async {
    calls.add('count');
    return queuedCount;
  }

  @override
  Future<void> refreshInventory() async {
    calls.add('refreshInventory');
    refreshCount++;
    if (failRefresh) throw StateError('cache unavailable');
  }

  @override
  Future<PendingSyncAuthorization> revalidateSession() async {
    calls.add('revalidate');
    return authorization;
  }

  @override
  Future<int> synchronizePendingSales() async {
    calls.add('synchronize');
    if (syncGate != null) await syncGate;
    if (failSync) throw StateError('queue unavailable');
    return remainingCount;
  }
}
