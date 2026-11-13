import 'dart:async';
import 'dart:io';

import 'package:core_logic/database/legacy_pending_sale_quarantine.dart';
import 'package:core_logic/database/pending_sale_queue_store.dart';
import 'package:core_logic/database/tenant_pending_sale_queue.dart';
import 'package:core_logic/features/ventas/domain/sale_models.dart';
import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:core_logic/sync/application/tenant_pending_sale_sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const user = '00000000-0000-0000-0000-000000000011';
  const otherUser = '00000000-0000-0000-0000-000000000012';
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  late Directory temp;
  late PendingSaleQueueStore historical;
  late LegacyPendingSaleQuarantine quarantine;
  final queues = <TenantPendingSaleQueue>[];

  String? signedIn = user;
  String? selected = orgA;
  int verifications = 0;
  VerifiedTenantRequestContext Function(TenantRequestScope scope)? verifyAs;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('stomni-scoped-sync-');
    historical = PendingSaleQueueStore(
      databaseFactoryOverride: databaseFactoryFfi,
      databasePathOverride: p.join(temp.path, 'ferreteria_pending_sales_v1.db'),
    );
    quarantine = LegacyPendingSaleQuarantine(historical);
    queues.clear();
    signedIn = user;
    selected = orgA;
    verifications = 0;
    verifyAs = null;
  });

  tearDown(() async {
    for (final queue in queues) {
      await queue.close();
    }
    await historical.close();
    await temp.delete(recursive: true);
  });

  TenantPendingSaleQueue newQueue(String organization) {
    final queue = TenantPendingSaleQueue(
      scope: TenantRequestScope(authUserId: user, organizationId: organization),
      currentAuthUserId: () => signedIn,
      currentSelectedOrganizationId: () => selected,
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryOverride: temp.path,
    );
    queues.add(queue);
    return queue;
  }

  TenantPendingSaleSyncCoordinator coordinator(
    TenantPendingSaleQueue queue,
    _FakeAdapter adapter, {
    Future<VerifiedTenantRequestContext> Function(TenantRequestScope)?
    verifyOverride,
  }) => TenantPendingSaleSyncCoordinator(
    queue: queue,
    scope: queue.scope,
    currentAuthUserId: () => signedIn,
    currentSelectedOrganizationId: () => selected,
    legacyQuarantine: quarantine,
    verifySelectedTenant: (scope) async {
      verifications++;
      if (verifyOverride != null) return verifyOverride(scope);
      return verifyAs?.call(scope) ??
          VerifiedTenantRequestContext(
            organizationId: scope.organizationId,
            baseRole: 'operador',
          );
    },
    adapter: adapter,
  );

  Map<String, dynamic> payload(String organization, {String id = 'same-id'}) =>
      <String, dynamic>{
        'request_id': id,
        'auth_user_id': user,
        'organization_id': organization,
        'fecha': '2026-11-13T11:00:00',
        'tipo_comprobante': 'ticket_interno',
        'total_a_pagar': 1.0,
        'cliente': <String, dynamic>{},
        'pagos': <Map<String, dynamic>>[],
        'detalles': <Map<String, dynamic>>[],
      };

  test(
    'submits only a server-verified tenant ticket, then removes its row',
    () async {
      final queue = newQueue(orgA);
      final adapter = _FakeAdapter();
      await queue.saveTicket(payload(orgA));
      final result = await coordinator(queue, adapter).synchronize();
      expect(result.submitted, 1);
      expect(result.failed, 0);
      expect(result.remaining, 0);
      expect(adapter.requestIds, ['same-id']);
      expect(adapter.tenants, [orgA]);
      expect(verifications, 2);
    },
  );

  test('equal request IDs in two organizations never mix queues', () async {
    final first = newQueue(orgA);
    final second = newQueue(orgB);
    await first.saveTicket(payload(orgA));
    selected = orgB;
    await second.saveTicket(payload(orgB));
    selected = orgA;
    final adapterA = _FakeAdapter();
    await coordinator(first, adapterA).synchronize();
    expect(adapterA.tenants, [orgA]);
    selected = orgB;
    final adapterB = _FakeAdapter();
    await coordinator(second, adapterB).synchronize();
    expect(adapterB.tenants, [orgB]);
    expect(await second.count(), 0);
    selected = orgA;
    expect(await first.count(), 0);
  });

  test(
    'wrong selected organization fails before server or local mutations',
    () async {
      final queue = newQueue(orgA);
      await queue.saveTicket(payload(orgA));
      selected = orgB;
      final adapter = _FakeAdapter();
      await expectLater(
        coordinator(queue, adapter).synchronize(),
        throwsStateError,
      );
      expect(adapter.requestIds, isEmpty);
      expect(verifications, 0);
      selected = orgA;
      expect(await queue.count(), 1);
    },
  );

  test('revoked or foreign server membership blocks submission', () async {
    final queue = newQueue(orgA);
    await queue.saveTicket(payload(orgA));
    verifyAs = (scope) => const VerifiedTenantRequestContext(
      organizationId: orgB,
      baseRole: 'admin',
    );
    final adapter = _FakeAdapter();
    await expectLater(
      coordinator(queue, adapter).synchronize(),
      throwsStateError,
    );
    expect(adapter.requestIds, isEmpty);
    expect(await queue.count(), 1);
  });

  test(
    'failed server write remains in the tenant queue for safe retry',
    () async {
      final queue = newQueue(orgA);
      await queue.saveTicket(payload(orgA));
      final adapter = _FakeAdapter()..failNext = true;
      final sync = coordinator(queue, adapter);
      final first = await sync.synchronize();
      expect(first.submitted, 0);
      expect(first.failed, 1);
      expect(first.remaining, 1);
      expect((await queue.list()).single.status, PendingSaleQueueStatus.failed);
      final retry = await sync.synchronize();
      expect(retry.submitted, 1);
      expect(retry.remaining, 0);
      expect(adapter.requestIds, ['same-id', 'same-id']);
    },
  );

  test(
    'session switch during network write retains in-flight ticket',
    () async {
      final queue = newQueue(orgA);
      await queue.saveTicket(payload(orgA));
      final gate = Completer<void>();
      final adapter = _FakeAdapter()..hold = gate;
      final sync = coordinator(queue, adapter);
      final inFlight = sync.synchronize();
      while (adapter.requestIds.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      signedIn = otherUser;
      gate.complete();
      await expectLater(inFlight, throwsStateError);
      signedIn = user;
      expect(
        (await queue.list()).single.status,
        PendingSaleQueueStatus.processing,
      );
      await queue.recoverInterruptedProcessing();
      expect(
        (await queue.list()).single.status,
        PendingSaleQueueStatus.pending,
      );
      adapter.hold = null;
      final retry = await sync.synchronize();
      expect(retry.submitted, 1);
      expect(await queue.count(), 0);
    },
  );

  test(
    'unattributed legacy SQLite ticket blocks all selected-company sync',
    () async {
      final queue = newQueue(orgA);
      await queue.saveTicket(payload(orgA));
      await historical.upsertPayload({
        'request_id': 'unattributed-historic',
        'tipo_comprobante': 'ticket_interno',
      });
      final adapter = _FakeAdapter();
      await expectLater(
        coordinator(queue, adapter).synchronize(),
        throwsStateError,
      );
      expect(adapter.requestIds, isEmpty);
      expect(
        (await historical.list()).single.requestId,
        'unattributed-historic',
      );
      expect(await queue.count(), 1);
    },
  );

  test('corrupt pending sale is marked failed instead of sent', () async {
    final queue = newQueue(orgA);
    final damaged = payload(orgA)..remove('fecha');
    await queue.saveTicket(damaged);
    final adapter = _FakeAdapter();
    final result = await coordinator(queue, adapter).synchronize();
    expect(result.failed, 1);
    expect(adapter.requestIds, isEmpty);
    expect((await queue.list()).single.status, PendingSaleQueueStatus.failed);
  });

  test(
    'a processing ticket is not automatically reset by another worker',
    () async {
      final queue = newQueue(orgA);
      await queue.saveTicket(payload(orgA));
      await queue.markProcessing('same-id');
      final adapter = _FakeAdapter();
      final result = await coordinator(queue, adapter).synchronize();
      expect(result.skippedProcessing, 1);
      expect(result.remaining, 1);
      expect(adapter.requestIds, isEmpty);
    },
  );

  test('simultaneous sync calls share one in-flight batch', () async {
    final queue = newQueue(orgA);
    await queue.saveTicket(payload(orgA));
    final gate = Completer<void>();
    final adapter = _FakeAdapter()..hold = gate;
    final sync = coordinator(queue, adapter);
    final a = sync.synchronize();
    final b = sync.synchronize();
    expect(identical(a, b), isTrue);
    while (adapter.requestIds.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    gate.complete();
    final result = await Future.wait([a, b]);
    expect(result.map((r) => r.submitted).toList(), [1, 1]);
    expect(adapter.requestIds.length, 1);
  });
}

final class _FakeAdapter implements TenantScopedSaleSyncAdapter {
  final requestIds = <String>[];
  final tenants = <String>[];
  bool failNext = false;
  Completer<void>? hold;

  @override
  Future<void> sendTicket({
    required TenantRequestScope scope,
    required PendingSale sale,
  }) async {
    requestIds.add(sale.requestId);
    tenants.add(scope.organizationId);
    final gate = hold;
    if (gate != null) await gate.future;
    if (failNext) {
      failNext = false;
      throw StateError('transient network failure');
    }
  }
}
