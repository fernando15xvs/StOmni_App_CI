import 'dart:async';

import 'sync_ports.dart';

class InventoryRealtimeEvent {
  InventoryRealtimeEvent({
    required Set<int> productosActualizados,
    required this.requiereRecargaKardex,
  }) : productosActualizados = Set<int>.unmodifiable(productosActualizados);

  final Set<int> productosActualizados;
  final bool requiereRecargaKardex;
}

class FinancialRealtimeEvent {
  const FinancialRealtimeEvent({required this.requiereRecargaReportesFinancieros});
  final bool requiereRecargaReportesFinancieros;
}

/// Agrupa cambios, reintenta fallos y publica resultados sin conocer plugins.
class InventorySyncCoordinator {
  InventorySyncCoordinator({
    required this.inventory,
    this.debounce = const Duration(milliseconds: 500),
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetries = 2,
  });

  final InventorySyncAdapter inventory;
  final Duration debounce;
  final Duration retryDelay;
  final int maxRetries;
  final _pending = <int, bool>{};
  final _retries = <int, int>{};
  final _events = StreamController<InventoryRealtimeEvent>.broadcast();
  Timer? _timer;
  Future<void>? _inFlight;
  bool _disposed = false;

  Stream<InventoryRealtimeEvent> get events => _events.stream;

  void productChanged(int id, {bool affectsLedger = false}) {
    if (_disposed || id <= 0) return;
    _pending[id] = (_pending[id] ?? false) || affectsLedger;
    _timer ??= Timer(debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    final active = _inFlight;
    if (active != null) return active;
    _timer?.cancel();
    _timer = null;
    final future = _flush();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
      if (!_disposed && _pending.isNotEmpty) {
        _timer?.cancel();
        _timer = Timer(retryDelay, () {
          _timer = null;
          unawaited(flush());
        });
      }
    });
  }

  Future<void> _flush() async {
    final batch = Map<int, bool>.from(_pending);
    _pending.clear();
    final succeeded = <int>{};
    var ledgerChanged = false;
    for (final entry in batch.entries) {
      if (_disposed) return;
      try {
        await inventory.sincronizarProducto(entry.key);
        if (_disposed) return;
        succeeded.add(entry.key);
        ledgerChanged = ledgerChanged || entry.value;
        _retries.remove(entry.key);
      } catch (_) {
        if (_disposed) return;
        final attempt = (_retries[entry.key] ?? 0) + 1;
        if (attempt <= maxRetries) {
          _retries[entry.key] = attempt;
          _pending[entry.key] = (_pending[entry.key] ?? false) || entry.value;
        } else {
          _retries.remove(entry.key);
        }
      }
    }
    if (!_disposed && succeeded.isNotEmpty) {
      _events.add(InventoryRealtimeEvent(
        productosActualizados: succeeded,
        requiereRecargaKardex: ledgerChanged,
      ));
    }
  }

  /// No elimina eventos recibidos mientras esperaba la actualización completa.
  Future<void> refreshAll() async {
    if (_disposed) return;
    await inventory.sincronizarTodo(propagarError: true);
    if (_disposed) return;
    _retries.clear();
    _events.add(InventoryRealtimeEvent(
      productosActualizados: const <int>{},
      requiereRecargaKardex: true,
    ));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _pending.clear();
    _retries.clear();
    unawaited(_events.close());
  }
}
