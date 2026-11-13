import 'dart:io';

import 'package:core_logic/database/pending_sale_queue_store.dart';
import 'package:core_logic/database/tenant_pending_sale_queue.dart';
import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const userA = '00000000-0000-0000-0000-000000000011';
  const userB = '00000000-0000-0000-0000-000000000012';
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  late Directory working;
  final stores = <TenantPendingSaleQueue>[];

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    working = await Directory.systemTemp.createTemp('stomni-queue-');
    stores.clear();
  });
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    await working.delete(recursive: true);
  });

  TenantPendingSaleQueue queue(
    String authUser,
    String organization, {
    String? Function()? session,
    String? Function()? selected,
  }) {
    final store = TenantPendingSaleQueue(
      scope: TenantRequestScope(
        authUserId: authUser,
        organizationId: organization,
      ),
      currentAuthUserId: session ?? () => authUser,
      currentSelectedOrganizationId: selected ?? () => organization,
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryOverride: working.path,
    );
    stores.add(store);
    return store;
  }

  Map<String, dynamic> ticket(
    String authUser,
    String organization, {
    String requestId = 'same-request-id',
    String item = 'Producto A',
  }) => {
    'auth_user_id': authUser,
    'organization_id': organization,
    'request_id': requestId,
    'tipo_comprobante': 'ticket_interno',
    'nombre_producto': item,
  };

  test('database and browser namespaces isolate both dimensions', () {
    final a = TenantPendingSaleQueue.databaseNameFor(userA, orgA);
    final b = TenantPendingSaleQueue.databaseNameFor(userA, orgB);
    final c = TenantPendingSaleQueue.databaseNameFor(userB, orgA);
    expect({a, b, c}.length, 3);
    expect(a.endsWith('.db'), isTrue);
    expect(
      TenantPendingSaleQueue.webKeyFor(userA, orgA),
      isNot(TenantPendingSaleQueue.webKeyFor(userA, orgB)),
    );
    expect(
      () => TenantPendingSaleQueue.databaseNameFor('../escape', orgA),
      throwsFormatException,
    );
  });

  test('same request_id in A and B never overwrites another company', () async {
    final a = queue(userA, orgA);
    final b = queue(userA, orgB);
    await a.saveTicket(ticket(userA, orgA, item: 'A inventory'));
    await b.saveTicket(ticket(userA, orgB, item: 'B inventory'));
    expect((await a.list()).single.payload['nombre_producto'], 'A inventory');
    expect((await b.list()).single.payload['nombre_producto'], 'B inventory');
    expect(await a.count(), 1);
    expect(await b.count(), 1);
  });

  test(
    'same organization and different users never share pending sales',
    () async {
      final a = queue(userA, orgA);
      final b = queue(userB, orgA);
      await a.saveTicket(ticket(userA, orgA, item: 'From user A'));
      await b.saveTicket(ticket(userB, orgA, item: 'From user B'));
      expect((await a.list()).single.payload['nombre_producto'], 'From user A');
      expect((await b.list()).single.payload['nombre_producto'], 'From user B');
    },
  );

  test('writes with a foreign or missing tenant owner fail closed', () async {
    final a = queue(userA, orgA);
    await expectLater(
      a.saveTicket({
        'request_id': 'missing-owner',
        'tipo_comprobante': 'ticket_interno',
      }),
      throwsStateError,
    );
    expect(await a.count(), 0);
  });

  test(
    'only internal tickets with request identifiers can be queued',
    () async {
      final a = queue(userA, orgA);
      final invoice = ticket(userA, orgA)..['tipo_comprobante'] = 'factura';
      await expectLater(a.saveTicket(invoice), throwsArgumentError);
      await expectLater(
        a.saveTicket(ticket(userA, orgA, requestId: '')),
        throwsArgumentError,
      );
      expect(await a.count(), 0);
    },
  );

  test('selection or Auth change blocks all queued data access', () async {
    String? selected = orgA;
    String? signedIn = userA;
    final a = queue(
      userA,
      orgA,
      session: () => signedIn,
      selected: () => selected,
    );
    await a.saveTicket(ticket(userA, orgA));
    selected = orgB;
    await expectLater(a.list(), throwsStateError);
    await expectLater(a.clearSelectedTenant(), throwsStateError);
    selected = orgA;
    signedIn = userB;
    await expectLater(a.count(), throwsStateError);
    signedIn = userA;
    expect(await a.count(), 1);
  });

  test('clearing A cannot erase the pending tickets of B', () async {
    final a = queue(userA, orgA);
    final b = queue(userA, orgB);
    await a.saveTicket(ticket(userA, orgA));
    await b.saveTicket(ticket(userA, orgB));
    await a.clearSelectedTenant();
    expect(await a.count(), 0);
    expect(await b.count(), 1);
  });

  test(
    'existing historical SQLite sales stay untouched and quarantined',
    () async {
      final legacy = PendingSaleQueueStore(
        databaseFactoryOverride: databaseFactoryFfi,
        databasePathOverride: p.join(
          working.path,
          'ferreteria_pending_sales_v1.db',
        ),
      );
      try {
        await legacy.upsertPayload({
          'request_id': 'historic-ticket',
          'tipo_comprobante': 'ticket_interno',
        });
        final a = queue(userA, orgA);
        expect(await a.count(), 0);
        expect((await legacy.list()).single.requestId, 'historic-ticket');
      } finally {
        await legacy.close();
      }
    },
  );

  test('foreign row injected into a tenant file cannot be returned', () async {
    final injected = PendingSaleQueueStore(
      databaseFactoryOverride: databaseFactoryFfi,
      databasePathOverride: p.join(
        working.path,
        TenantPendingSaleQueue.databaseNameFor(userA, orgA),
      ),
    );
    await injected.upsertPayload(ticket(userA, orgB));
    await injected.close();

    final a = queue(userA, orgA);
    await expectLater(a.list(), throwsStateError);
    await expectLater(a.count(), throwsStateError);
  });

  test('deleting by request id affects selected company only', () async {
    final a = queue(userA, orgA);
    final b = queue(userA, orgB);
    await a.saveTicket(ticket(userA, orgA));
    await b.saveTicket(ticket(userA, orgB));
    await a.deleteByRequestId('same-request-id');
    expect(await a.count(), 0);
    expect(await b.count(), 1);
  });
}
