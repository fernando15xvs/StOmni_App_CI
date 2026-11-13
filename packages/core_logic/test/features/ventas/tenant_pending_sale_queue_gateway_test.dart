import 'dart:io';

import 'package:core_logic/database/tenant_pending_sale_queue.dart';
import 'package:core_logic/features/ventas/data/pending_sale_mapper.dart';
import 'package:core_logic/features/ventas/data/tenant_pending_sale_queue_gateway.dart';
import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const user = '00000000-0000-0000-0000-000000000011';
  const otherUser = '00000000-0000-0000-0000-000000000012';
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  late Directory temp;
  String? authUser = user;
  String? selected = orgA;
  final stores = <TenantPendingSaleQueue>[];

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stomni-submit-queue-');
    stores.clear();
    authUser = user;
    selected = orgA;
  });
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    await temp.delete(recursive: true);
  });

  TenantPendingSaleQueue queue(String organizationId) {
    final store = TenantPendingSaleQueue(
      scope: TenantRequestScope(
        authUserId: user,
        organizationId: organizationId,
      ),
      currentAuthUserId: () => authUser,
      currentSelectedOrganizationId: () => selected,
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryOverride: temp.path,
    );
    stores.add(store);
    return store;
  }

  Map<String, dynamic> saleMap({
    String authUserId = user,
    String type = 'ticket_interno',
  }) => {
    'request_id': 'shared-sale-id',
    'auth_user_id': authUserId,
    'fecha': '2026-11-13T14:15:00',
    'tipo_comprobante': type,
    'cliente': <String, dynamic>{},
    'pagos': <Map<String, dynamic>>[],
    'detalles': <Map<String, dynamic>>[],
  };

  test(
    'existing sale submission port stages ticket with verified tenant id',
    () async {
      final store = queue(orgA);
      final gateway = TenantPendingSaleQueueGateway(store);
      await gateway.enqueue(PendingSaleMapper.decode(saleMap()));
      final records = await store.list();
      expect(records.length, 1);
      expect(records.single.payload['organization_id'], orgA);
      expect(records.single.payload['auth_user_id'], user);
      expect(records.single.payload['schema_version'], 3);
      expect(records.single.requestId, 'shared-sale-id');
    },
  );

  test(
    'other Auth user cannot inject ticket into current tenant queue',
    () async {
      final store = queue(orgA);
      final gateway = TenantPendingSaleQueueGateway(store);
      await expectLater(
        gateway.enqueue(
          PendingSaleMapper.decode(saleMap(authUserId: otherUser)),
        ),
        throwsStateError,
      );
      expect(await store.count(), 0);
    },
  );

  test(
    'sale submission adapter rejects invoices and never queues fiscal docs',
    () async {
      final store = queue(orgA);
      final gateway = TenantPendingSaleQueueGateway(store);
      await expectLater(
        gateway.enqueue(PendingSaleMapper.decode(saleMap(type: 'factura'))),
        throwsStateError,
      );
      expect(await store.count(), 0);
    },
  );

  test(
    'parallel company queues cannot overwrite one shared request ID',
    () async {
      final first = queue(orgA);
      final second = queue(orgB);
      await TenantPendingSaleQueueGateway(
        first,
      ).enqueue(PendingSaleMapper.decode(saleMap()));
      selected = orgB;
      await TenantPendingSaleQueueGateway(
        second,
      ).enqueue(PendingSaleMapper.decode(saleMap()));
      expect((await second.list()).single.payload['organization_id'], orgB);
      selected = orgA;
      expect((await first.list()).single.payload['organization_id'], orgA);
    },
  );

  test(
    'session or tenant change blocks the submission port before storage',
    () async {
      final store = queue(orgA);
      final gateway = TenantPendingSaleQueueGateway(store);
      selected = orgB;
      await expectLater(
        gateway.enqueue(PendingSaleMapper.decode(saleMap())),
        throwsStateError,
      );
      selected = orgA;
      authUser = otherUser;
      await expectLater(
        gateway.enqueue(PendingSaleMapper.decode(saleMap())),
        throwsStateError,
      );
      authUser = user;
      expect(await store.count(), 0);
    },
  );
}
