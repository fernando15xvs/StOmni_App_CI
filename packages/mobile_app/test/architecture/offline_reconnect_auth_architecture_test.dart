import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('core revalida antes de leer y sincronizar la cola', () {
    final useCase = coreFile(
      'lib/sync/application/sync_pending_operations_use_case.dart',
    ).readAsStringSync();

    final revalidateIndex = useCase.indexOf('gateway.revalidateSession()');
    final pendingIndex = useCase.indexOf('gateway.pendingSalesCount()');
    final syncIndex = useCase.indexOf('gateway.synchronizePendingSales()');

    expect(revalidateIndex, greaterThanOrEqualTo(0));
    expect(pendingIndex, greaterThan(revalidateIndex));
    expect(syncIndex, greaterThan(pendingIndex));
    expect(useCase, contains('PendingSyncAuthorization.denied'));
    expect(useCase, contains('PendingSyncAuthorization.unavailable'));
  });

  test('conectividad y frameworks de plataforma quedan en mobile_app', () {
    final legacyController = coreFile(
      'lib/services/connectivity_sync_controller.dart',
    );
    final useCase = coreFile(
      'lib/sync/application/sync_pending_operations_use_case.dart',
    ).readAsStringSync();
    final mobileController = File(
      'lib/platform/connectivity/connectivity_sync_controller.dart',
    ).readAsStringSync();

    expect(legacyController.existsSync(), isFalse);
    expect(useCase, isNot(contains('connectivity_plus')));
    expect(useCase, isNot(contains('flutter_riverpod')));
    expect(useCase, isNot(contains('supabase_flutter')));
    expect(mobileController, contains('package:connectivity_plus/'));
    expect(mobileController, contains('SyncPendingOperationsUseCase'));
    expect(mobileController, contains('ref.read(syncPendingOperationsProvider)'));
    expect(mobileController, isNot(contains('supabase_flutter')));
    final composition = File(
      'lib/app/providers/sync_providers.dart',
    ).readAsStringSync();
    expect(composition, contains('auth.currentUser'));
    expect(composition, contains('revalidateCurrentSession()'));
    expect(composition, contains('OfflineService.sincronizarVentasPendientes('));
  });

  test('offline y realtime no conocen estado ni lifecycle móviles', () {
    final offline = coreFile('lib/services/offline_service.dart').readAsStringSync();
    final realtime = coreFile(
      'lib/sync/application/inventory_sync_coordinator.dart',
    ).readAsStringSync();
    for (final source in [offline, realtime]) {
      expect(source, isNot(contains('flutter_riverpod')));
      expect(source, isNot(contains('connectivity_plus')));
      expect(source, isNot(contains('ref.read(')));
      expect(source, isNot(contains('AppLifecycleListener')));
    }
    expect(offline, contains('PendingSaleSyncAdapter saleSyncAdapter'));
    expect(realtime, contains('InventorySyncAdapter'));
  });

  test('revalidación denegada limpia autorización local', () {
    final controller = coreFile(
      'lib/auth/controllers/auth_controller.dart',
    ).readAsStringSync();

    expect(controller, contains('Future<AuthRevalidationResult>'));
    expect(controller, contains('revalidateCurrentSession()'));
    expect(
      controller,
      contains('_safeSignOut(clearOfflineAuthorization: true)'),
    );
  });
}
