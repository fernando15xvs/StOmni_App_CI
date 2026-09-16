import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../utils/app_time.dart';

class PendingSaleQueueStatus {
  static const pending = 'pendiente';
  static const processing = 'procesando';
  static const failed = 'fallida';

  static const values = {pending, processing, failed};
}

class PendingSaleQueueRecord {
  const PendingSaleQueueRecord({
    required this.requestId,
    required this.payload,
    required this.status,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
    this.lastAttemptAt,
  });

  final String requestId;
  final Map<String, dynamic> payload;
  final String status;
  final int attempts;
  final String? lastError;
  final String createdAt;
  final String? lastAttemptAt;
  final String updatedAt;

  factory PendingSaleQueueRecord.fromStorage(Map<String, Object?> row) {
    final rawPayload = row['payload_json']?.toString() ?? '{}';
    final decoded = jsonDecode(rawPayload);
    if (decoded is! Map) {
      throw const FormatException('Payload de venta pendiente inválido.');
    }

    final status = row['estado']?.toString() ?? PendingSaleQueueStatus.pending;
    return PendingSaleQueueRecord(
      requestId: row['request_id']?.toString() ?? '',
      payload: Map<String, dynamic>.from(decoded),
      status: PendingSaleQueueStatus.values.contains(status)
          ? status
          : PendingSaleQueueStatus.pending,
      attempts: (row['intentos'] as num?)?.toInt() ?? 0,
      lastError: row['ultimo_error']?.toString(),
      createdAt: row['creado_en']?.toString() ?? '',
      lastAttemptAt: row['ultimo_intento_en']?.toString(),
      updatedAt: row['actualizado_en']?.toString() ?? '',
    );
  }

  Map<String, Object?> toStorage() => {
    'request_id': requestId,
    'payload_json': jsonEncode(payload),
    'estado': status,
    'intentos': attempts,
    'ultimo_error': lastError,
    'creado_en': createdAt,
    'ultimo_intento_en': lastAttemptAt,
    'actualizado_en': updatedAt,
  };

  Map<String, dynamic> toPayloadView() {
    return <String, dynamic>{
      ...payload,
      '_queue_estado': status,
      '_queue_intentos': attempts,
      '_queue_ultimo_error': lastError,
      '_queue_ultimo_intento': lastAttemptAt,
    };
  }
}

/// Persistencia durable de ventas pendientes.
///
/// En Android/iOS/Windows/Linux/macOS usa un SQLite dedicado para no mezclar
/// la cola transaccional con el caché descartable de productos. En Web se
/// conserva un fallback compatible en SharedPreferences porque `sqflite` no
/// dispone de backend web en este proyecto.
class PendingSaleQueueStore {
  PendingSaleQueueStore({
    DatabaseFactory? databaseFactoryOverride,
    String? databasePathOverride,
  }) : _databaseFactoryOverride = databaseFactoryOverride,
       _databasePathOverride = databasePathOverride;

  static const _dbName = 'ferreteria_pending_sales_v1.db';
  static const _table = 'ventas_pendientes';
  static const _webStorageKey = 'ventas_pendientes_queue_web_v1';

  final DatabaseFactory? _databaseFactoryOverride;
  final String? _databasePathOverride;
  Database? _databaseInstance;

  Future<Database> _database() async {
    final existing = _databaseInstance;
    if (existing != null) return existing;

    final factory = _databaseFactoryOverride ?? databaseFactory;
    final path =
        _databasePathOverride ??
        p.join(await factory.getDatabasesPath(), _dbName);
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE $_table (
              request_id TEXT PRIMARY KEY,
              payload_json TEXT NOT NULL,
              estado TEXT NOT NULL DEFAULT '${PendingSaleQueueStatus.pending}',
              intentos INTEGER NOT NULL DEFAULT 0,
              ultimo_error TEXT,
              creado_en TEXT NOT NULL,
              ultimo_intento_en TEXT,
              actualizado_en TEXT NOT NULL,
              CHECK (estado IN ('${PendingSaleQueueStatus.pending}', '${PendingSaleQueueStatus.processing}', '${PendingSaleQueueStatus.failed}')),
              CHECK (intentos >= 0)
            )
          ''');
          await database.execute(
            'CREATE INDEX idx_ventas_pendientes_estado ON $_table(estado)',
          );
          await database.execute(
            'CREATE INDEX idx_ventas_pendientes_actualizado ON $_table(actualizado_en)',
          );
        },
      ),
    );
    _databaseInstance = db;
    return db;
  }

  Future<void> upsertPayload(Map<String, dynamic> payload) async {
    final requestId = payload['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) {
      throw ArgumentError('La venta pendiente debe contener request_id.');
    }

    if (kIsWeb) {
      final records = await _readWebRecords();
      final index = records.indexWhere(
        (record) => record.requestId == requestId,
      );
      final now = AppTime.nowIso();
      final previous = index >= 0 ? records[index] : null;
      final next = PendingSaleQueueRecord(
        requestId: requestId,
        payload: Map<String, dynamic>.from(payload),
        status: PendingSaleQueueStatus.pending,
        attempts: previous?.attempts ?? 0,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
      );
      if (index >= 0) {
        records[index] = next;
      } else {
        records.add(next);
      }
      await _writeWebRecords(records);
      return;
    }

    final db = await _database();
    await db.transaction((txn) async {
      final existing = await txn.query(
        _table,
        columns: ['creado_en', 'intentos'],
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      final now = AppTime.nowIso();
      final createdAt = existing.isEmpty
          ? now
          : existing.first['creado_en']?.toString() ?? now;
      final attempts = existing.isEmpty
          ? 0
          : (existing.first['intentos'] as num?)?.toInt() ?? 0;

      await txn.insert(
        _table,
        PendingSaleQueueRecord(
          requestId: requestId,
          payload: Map<String, dynamic>.from(payload),
          status: PendingSaleQueueStatus.pending,
          attempts: attempts,
          createdAt: createdAt,
          updatedAt: now,
        ).toStorage(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<PendingSaleQueueRecord>> list() async {
    if (kIsWeb) return _readWebRecords();

    final db = await _database();
    final rows = await db.query(_table, orderBy: 'creado_en ASC');
    return rows
        .map((row) => PendingSaleQueueRecord.fromStorage(row))
        .toList(growable: false);
  }

  Future<void> markProcessing(String requestId) async {
    final now = AppTime.nowIso();
    if (kIsWeb) {
      await _mutateWebRecord(requestId, (record) {
        return PendingSaleQueueRecord(
          requestId: record.requestId,
          payload: record.payload,
          status: PendingSaleQueueStatus.processing,
          attempts: record.attempts + 1,
          lastError: record.lastError,
          createdAt: record.createdAt,
          lastAttemptAt: now,
          updatedAt: now,
        );
      });
      return;
    }

    final db = await _database();
    await db.rawUpdate(
      '''
      UPDATE $_table
      SET estado = ?, intentos = intentos + 1, ultimo_intento_en = ?, actualizado_en = ?
      WHERE request_id = ?
      ''',
      [PendingSaleQueueStatus.processing, now, now, requestId],
    );
  }

  Future<void> markFailed(String requestId, Object error) async {
    final message = error.toString();
    final now = AppTime.nowIso();
    if (kIsWeb) {
      await _mutateWebRecord(requestId, (record) {
        return PendingSaleQueueRecord(
          requestId: record.requestId,
          payload: record.payload,
          status: PendingSaleQueueStatus.failed,
          attempts: record.attempts,
          lastError: message,
          createdAt: record.createdAt,
          lastAttemptAt: record.lastAttemptAt ?? now,
          updatedAt: now,
        );
      });
      return;
    }

    final db = await _database();
    await db.update(
      _table,
      {
        'estado': PendingSaleQueueStatus.failed,
        'ultimo_error': message,
        'actualizado_en': now,
      },
      where: 'request_id = ?',
      whereArgs: [requestId],
    );
  }

  /// Si la aplicación se cerró entre el RPC exitoso y la eliminación local,
  /// la fila puede quedar `procesando`. Se recupera a `pendiente`; el mismo
  /// request_id hace seguro el reintento contra el backend idempotente.
  Future<void> recoverInterruptedProcessing() async {
    final now = AppTime.nowIso();
    if (kIsWeb) {
      final records = await _readWebRecords();
      var changed = false;
      for (var index = 0; index < records.length; index++) {
        final record = records[index];
        if (record.status != PendingSaleQueueStatus.processing) continue;
        records[index] = PendingSaleQueueRecord(
          requestId: record.requestId,
          payload: record.payload,
          status: PendingSaleQueueStatus.pending,
          attempts: record.attempts,
          lastError: record.lastError,
          createdAt: record.createdAt,
          lastAttemptAt: record.lastAttemptAt,
          updatedAt: now,
        );
        changed = true;
      }
      if (changed) await _writeWebRecords(records);
      return;
    }

    final db = await _database();
    await db.update(
      _table,
      {'estado': PendingSaleQueueStatus.pending, 'actualizado_en': now},
      where: 'estado = ?',
      whereArgs: [PendingSaleQueueStatus.processing],
    );
  }

  Future<void> deleteByRequestId(String requestId) async {
    if (kIsWeb) {
      final records = await _readWebRecords();
      records.removeWhere((record) => record.requestId == requestId);
      await _writeWebRecords(records);
      return;
    }

    final db = await _database();
    await db.delete(_table, where: 'request_id = ?', whereArgs: [requestId]);
  }

  Future<void> clear() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_webStorageKey);
      return;
    }

    final db = await _database();
    await db.delete(_table);
  }

  Future<int> count() async {
    if (kIsWeb) return (await _readWebRecords()).length;

    final db = await _database();
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $_table'),
        ) ??
        0;
  }

  Future<List<PendingSaleQueueRecord>> _readWebRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_webStorageKey);
    if (raw == null || raw.isEmpty) return <PendingSaleQueueRecord>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PendingSaleQueueRecord>[];
      return decoded
          .whereType<Map>()
          .map(
            (item) => PendingSaleQueueRecord.fromStorage(
              Map<String, Object?>.from(item),
            ),
          )
          .toList();
    } catch (_) {
      return <PendingSaleQueueRecord>[];
    }
  }

  Future<void> _writeWebRecords(List<PendingSaleQueueRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    if (records.isEmpty) {
      await prefs.remove(_webStorageKey);
      return;
    }
    await prefs.setString(
      _webStorageKey,
      jsonEncode(records.map((record) => record.toStorage()).toList()),
    );
  }

  Future<void> _mutateWebRecord(
    String requestId,
    PendingSaleQueueRecord Function(PendingSaleQueueRecord current) transform,
  ) async {
    final records = await _readWebRecords();
    final index = records.indexWhere((record) => record.requestId == requestId);
    if (index < 0) return;
    records[index] = transform(records[index]);
    await _writeWebRecords(records);
  }

  @visibleForTesting
  Future<void> close() async {
    final db = _databaseInstance;
    _databaseInstance = null;
    await db?.close();
  }
}
