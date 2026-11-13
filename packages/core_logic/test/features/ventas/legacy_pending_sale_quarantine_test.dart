import 'dart:io';

import 'package:core_logic/database/legacy_pending_sale_quarantine.dart';
import 'package:core_logic/database/pending_sale_queue_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late PendingSaleQueueStore legacy;
  late LegacyPendingSaleQuarantine gate;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('stomni-legacy-queue-');
    legacy = PendingSaleQueueStore(
      databaseFactoryOverride: databaseFactoryFfi,
      databasePathOverride: p.join(temp.path, 'ferreteria_pending_sales_v1.db'),
    );
    gate = LegacyPendingSaleQuarantine(legacy);
  });

  tearDown(() async {
    await legacy.close();
    await temp.delete(recursive: true);
  });

  test('empty historical stores allow readiness inspection', () async {
    final status = await gate.inspect();
    expect(status.sqliteCount, 0);
    expect(status.preferencesCount, 0);
    expect(status.malformedHistoricalPayload, isFalse);
    expect(status.safeToSwitch, isTrue);
    await gate.requireNoUnattributedTickets();
  });

  test(
    'historical SQLite ticket blocks activation without erasing it',
    () async {
      await legacy.upsertPayload({
        'request_id': 'historic-1',
        'tipo_comprobante': 'ticket_interno',
      });
      final status = await gate.inspect();
      expect(status.sqliteCount, 1);
      expect(status.safeToSwitch, isFalse);
      await expectLater(gate.requireNoUnattributedTickets(), throwsStateError);
      expect((await legacy.list()).single.requestId, 'historic-1');
    },
  );

  test('old shared preferences ticket is quarantined, not migrated', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      LegacyPendingSaleQuarantine.historicalPreferencesKey,
      '[{"request_id":"old-pending-ticket"}]',
    );
    final status = await gate.inspect();
    expect(status.preferencesCount, 1);
    expect(status.safeToSwitch, isFalse);
    await expectLater(gate.requireNoUnattributedTickets(), throwsStateError);
    expect(prefs.getString('ventas_pendientes'), isNotNull);
  });

  test('corrupt historical sales cannot be silently ignored', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      LegacyPendingSaleQuarantine.historicalPreferencesKey,
      '{"unexpected":"payload"}',
    );
    final status = await gate.inspect();
    expect(status.malformedHistoricalPayload, isTrue);
    await expectLater(gate.requireNoUnattributedTickets(), throwsStateError);
  });

  test(
    'legacy global catalog alone is disposable and does not block',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('catalogo_cache', '[{"legacy":true}]');
      expect((await gate.inspect()).safeToSwitch, isTrue);
      await gate.requireNoUnattributedTickets();
      expect(prefs.getString('catalogo_cache'), isNotNull);
    },
  );

  test(
    'counts both historical sources before allowing tenant switch',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        LegacyPendingSaleQuarantine.historicalPreferencesKey,
        '[{"request_id":"one"},{"request_id":"two"}]',
      );
      await legacy.upsertPayload({
        'request_id': 'third',
        'tipo_comprobante': 'ticket_interno',
      });
      final status = await gate.inspect();
      expect(status.sqliteCount, 1);
      expect(status.preferencesCount, 2);
      expect(status.safeToSwitch, isFalse);
      await expectLater(gate.requireNoUnattributedTickets(), throwsStateError);
    },
  );
}
