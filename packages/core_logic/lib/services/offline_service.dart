import '../features/ventas/data/pending_sale_mapper.dart';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../database/pending_sale_queue_store.dart';
import 'sync_adapters.dart';

class OfflineService {
  static const String _keyCatalogo = 'catalogo_cache';
  static const String _legacyVentasPendientesKey = 'ventas_pendientes';
  static const String _queueMigrationKey = 'ventas_pendientes_sqlite_v1_migrated';

  static final PendingSaleQueueStore _queueStore = PendingSaleQueueStore();
  static Future<List<Map<String, dynamic>>>? _syncVentasEnCurso;
  static Future<void>? _queueReadyFuture;
  static bool _queueReady = false;

  static Future<void> guardarCatalogo(
    List<Map<String, dynamic>> productos,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyCatalogo, jsonEncode(productos));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> obtenerCatalogoCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_keyCatalogo);
      if (jsonString == null || jsonString.isEmpty) return [];

      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Guarda un Ticket Interno pendiente en almacenamiento durable.
  ///
  /// En plataformas nativas/escritorio la cola vive en SQLite. Web conserva
  /// un fallback compatible porque este proyecto no tiene backend sqflite web.
  static Future<void> guardarVentaOffline(
    Map<String, dynamic> datosVenta,
  ) async {
    final requestId = datosVenta['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) {
      throw ArgumentError('La venta offline debe contener un request_id.');
    }

    final tipoComprobante =
        datosVenta['tipo_comprobante']?.toString().trim().toLowerCase() ??
        'ticket_interno';
    if (tipoComprobante != 'ticket_interno') {
      throw ArgumentError(
        'La cola offline acepta únicamente Ticket Interno.',
      );
    }

    final payload = Map<String, dynamic>.from(datosVenta);
    payload['request_id'] = requestId;
    payload['tipo_comprobante'] = 'ticket_interno';

    await _ensureQueueReady();
    await _queueStore.upsertPayload(payload);
  }

  static Future<List<Map<String, dynamic>>> obtenerVentasOffline() async {
    await _ensureQueueReady();
    final records = await _queueStore.list();
    return records.map((record) => record.toPayloadView()).toList();
  }

  static Future<int> cantidadVentasPendientes() async {
    await _ensureQueueReady();
    return _queueStore.count();
  }

  /// Compatibilidad con la UI antigua que elimina por posición visual.
  static Future<void> eliminarVentaOffline(int index) async {
    try {
      await _ensureQueueReady();
      final records = await _queueStore.list();
      if (index < 0 || index >= records.length) return;
      await _queueStore.deleteByRequestId(records[index].requestId);
    } catch (_) {}
  }

  static Future<void> eliminarVentaOfflinePorRequestId(String requestId) async {
    await _ensureQueueReady();
    await _queueStore.deleteByRequestId(requestId.trim());
  }

  static Future<void> limpiarVentasOffline() async {
    await _ensureQueueReady();
    await _queueStore.clear();
  }

  /// Single-flight: si la reconexión automática y el botón manual coinciden,
  /// ambos esperan la misma sincronización en vez de procesar la cola dos veces.
  static Future<List<Map<String, dynamic>>> sincronizarVentasPendientes(
    PendingSaleSyncAdapter saleSyncAdapter,
  ) async {
    final enCurso = _syncVentasEnCurso;
    if (enCurso != null) return enCurso;

    final future = _sincronizarVentasPendientesInterno(saleSyncAdapter);
    _syncVentasEnCurso = future;

    try {
      return await future;
    } finally {
      if (identical(_syncVentasEnCurso, future)) {
        _syncVentasEnCurso = null;
      }
    }
  }

  static Future<List<Map<String, dynamic>>>
  _sincronizarVentasPendientesInterno(
    PendingSaleSyncAdapter saleSyncAdapter,
  ) async {
    await _ensureQueueReady();
    final recordsOriginales = await _queueStore.list();
    if (recordsOriginales.isEmpty) return [];

    for (final record in recordsOriginales) {
      final venta = Map<String, dynamic>.from(record.payload);
      final requestId = record.requestId;
      venta['request_id'] = requestId;

      final tipoComprobante =
          venta['tipo_comprobante']?.toString().trim().toLowerCase() ??
          'ticket_interno';
      if (tipoComprobante != 'ticket_interno') {
        await _queueStore.markFailed(
          requestId,
          'La cola offline acepta únicamente Ticket Interno. '
          'Registra nuevamente la venta con conexión si necesitas un '
          'comprobante electrónico.',
        );
        continue;
      }
      venta['tipo_comprobante'] = 'ticket_interno';

      await _queueStore.markProcessing(requestId);
      try {
        await saleSyncAdapter.sincronizarVenta(PendingSaleMapper.decode(venta));
        await _queueStore.deleteByRequestId(requestId);
      } catch (error) {
        await _queueStore.markFailed(requestId, error);
      }
    }

    final restantes = await _queueStore.list();
    return restantes.map((record) => record.toPayloadView()).toList();
  }

  /// Migra una sola vez la cola histórica de SharedPreferences hacia el store
  /// nuevo. El valor legado solo se elimina después de persistir todos los
  /// elementos, evitando pérdida de ventas durante una actualización.
  static Future<void> _ensureQueueReady() async {
    if (_queueReady) return;
    final existing = _queueReadyFuture;
    if (existing != null) return existing;

    final future = _initializeQueue();
    _queueReadyFuture = future;
    try {
      await future;
      _queueReady = true;
    } finally {
      if (identical(_queueReadyFuture, future)) {
        _queueReadyFuture = null;
      }
    }
  }

  static Future<void> _initializeQueue() async {
    await _queueStore.recoverInterruptedProcessing();

    final prefs = await SharedPreferences.getInstance();
    final legacyRaw = prefs.getString(_legacyVentasPendientesKey);
    if (legacyRaw != null && legacyRaw.trim().isNotEmpty) {
      final decoded = jsonDecode(legacyRaw);
      if (decoded is! List) {
        throw const FormatException('La cola offline histórica no es una lista.');
      }

      for (final rawItem in decoded) {
        if (rawItem is! Map) continue;
        final venta = Map<String, dynamic>.from(rawItem);
        final currentRequestId = venta['request_id']?.toString().trim() ?? '';
        venta['request_id'] = currentRequestId.isEmpty
            ? const Uuid().v4()
            : currentRequestId;
        await _queueStore.upsertPayload(venta);
      }

      await prefs.remove(_legacyVentasPendientesKey);
    }

    await prefs.setBool(_queueMigrationKey, true);
  }

  static Future<bool> queueMigrationCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_queueMigrationKey) == true;
  }
}
