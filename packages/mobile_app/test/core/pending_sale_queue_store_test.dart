import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  sqfliteFfiInit();

  late PendingSaleQueueStore store;

  setUp(() {
    store = PendingSaleQueueStore(
      databaseFactoryOverride: databaseFactoryFfi,
      databasePathOverride: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await store.close();
  });

  test('request_id es único y un upsert no duplica la venta', () async {
    await store.upsertPayload({
      'request_id': 'req-1',
      'tipo_comprobante': 'ticket_interno',
      'total_a_pagar': 10.0,
    });
    await store.upsertPayload({
      'request_id': 'req-1',
      'tipo_comprobante': 'ticket_interno',
      'total_a_pagar': 15.0,
    });

    final records = await store.list();
    expect(records, hasLength(1));
    expect(records.single.requestId, 'req-1');
    expect(records.single.payload['total_a_pagar'], 15.0);
    expect(records.single.status, PendingSaleQueueStatus.pending);
    expect(records.single.attempts, 0);
  });

  test(
    'procesamiento incrementa intentos y conserva el último error',
    () async {
      await store.upsertPayload({
        'request_id': 'req-2',
        'tipo_comprobante': 'ticket_interno',
      });

      await store.markProcessing('req-2');
      await store.markFailed('req-2', 'sin conexión');

      final record = (await store.list()).single;
      expect(record.status, PendingSaleQueueStatus.failed);
      expect(record.attempts, 1);
      expect(record.lastAttemptAt, isNotNull);
      expect(record.lastError, contains('sin conexión'));
    },
  );

  test(
    'una venta interrumpida vuelve a pendiente para retry idempotente',
    () async {
      await store.upsertPayload({
        'request_id': 'req-3',
        'tipo_comprobante': 'ticket_interno',
      });
      await store.markProcessing('req-3');

      expect(
        (await store.list()).single.status,
        PendingSaleQueueStatus.processing,
      );

      await store.recoverInterruptedProcessing();

      final recovered = (await store.list()).single;
      expect(recovered.status, PendingSaleQueueStatus.pending);
      expect(recovered.attempts, 1);
    },
  );

  test('vista de cola expone estado, intentos y último error', () async {
    await store.upsertPayload({
      'request_id': 'req-4',
      'tipo_comprobante': 'ticket_interno',
      'total_a_pagar': 25.0,
    });
    await store.markProcessing('req-4');
    await store.markFailed('req-4', 'servidor no disponible');

    final view = (await store.list()).single.toPayloadView();
    expect(view['request_id'], 'req-4');
    expect(view['_queue_estado'], PendingSaleQueueStatus.failed);
    expect(view['_queue_intentos'], 1);
    expect(view['_queue_ultimo_error'], contains('servidor no disponible'));
    expect(view['_queue_ultimo_intento'], isNotNull);
  });

  test('eliminación por request_id no depende del orden visual', () async {
    await store.upsertPayload({
      'request_id': 'req-a',
      'tipo_comprobante': 'ticket_interno',
    });
    await store.upsertPayload({
      'request_id': 'req-b',
      'tipo_comprobante': 'ticket_interno',
    });

    await store.deleteByRequestId('req-a');

    final records = await store.list();
    expect(records, hasLength(1));
    expect(records.single.requestId, 'req-b');
  });
}
