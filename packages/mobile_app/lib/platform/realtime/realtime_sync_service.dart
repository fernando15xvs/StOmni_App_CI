import 'dart:async';

import 'package:core_logic/core_logic.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/providers/sync_providers.dart';
import '../connectivity/connectivity_sync_controller.dart';

final reportesInventarioRevisionProvider = StateProvider<int>((ref) => 0);
final reportesFinancierosRevisionProvider = StateProvider<int>((ref) => 0);

final realtimeSyncServiceProvider = Provider<RealtimeInventorySyncService>((ref) {
  final service = RealtimeInventorySyncService(
    ref,
    ref.read(supabaseProvider),
    InventorySyncCoordinator(inventory: ref.read(inventorySyncAdapterProvider)),
  );
  ref.onDispose(service.dispose);
  return service;
});

final inventoryRealtimeEventStreamProvider =
    StreamProvider<InventoryRealtimeEvent>((ref) {
  return ref.watch(realtimeSyncServiceProvider).eventStream;
});

/// Adapta canales y lifecycle al motor reutilizable de core_logic.
class RealtimeInventorySyncService {
  RealtimeInventorySyncService(this._ref, this._client, this._coordinator) {
    _revisionSubscription = _coordinator.events.listen((_) {
      if (!_disposed) {
        _ref.read(reportesInventarioRevisionProvider.notifier).state++;
      }
    });
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(_recover());
    });
    _connect();
  }

  final Ref _ref;
  final SupabaseClient _client;
  final InventorySyncCoordinator _coordinator;
  RealtimeChannel? _channel;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<InventoryRealtimeEvent>? _revisionSubscription;
  bool _disposed = false;

  Stream<InventoryRealtimeEvent> get eventStream => _coordinator.events;

  void _connect() {
    _channel = _client.channel('public:inventario_global');
    for (final table in ['productos', 'inventario_almacen', 'inventario_movimientos']) {
      final ledger = table == 'inventario_movimientos';
      final key = table == 'productos' ? 'id' : 'producto_id';
      _channel!.onPostgresChanges(
        event: ledger ? PostgresChangeEvent.insert : PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (payload) {
          if (_disposed) return;
          final id = payload.newRecord[key] ?? payload.oldRecord[key];
          if (id is num) {
            _coordinator.productChanged(id.toInt(), affectsLedger: ledger);
          }
          final movementId = payload.newRecord['id'];
          if (ledger && movementId is num) {
            unawaited(_saveLedgerCheckpoint(movementId.toInt()));
          }
        },
      );
    }
    _channel!.subscribe();
  }

  Future<void> _recover() async {
    if (_disposed || _client.auth.currentUser == null) return;
    try {
      // Reanudación y reconexión comparten autorización y single-flight.
      final result = await _ref
          .read(connectivitySyncControllerProvider.notifier)
          .syncPendingSales();
      if (_disposed || result == null ||
          result.outcome == PendingOperationsSyncOutcome.requireLogin ||
          result.outcome == PendingOperationsSyncOutcome.authorizationUnavailable) {
        return;
      }
      await _coordinator.refreshAll();
    } catch (error) {
      debugPrint('No se pudo completar la recuperación de inventario: $error');
    }
  }

  Future<void> _saveLedgerCheckpoint(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id > (prefs.getInt('ultimo_kardex_id') ?? 0)) {
        await prefs.setInt('ultimo_kardex_id', id);
      }
    } catch (error) {
      debugPrint('No se pudo guardar el checkpoint de Kardex: $error');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.dispose();
    unawaited(_revisionSubscription?.cancel());
    final channel = _channel;
    if (channel != null) {
      unawaited(_removeChannel(_client, channel));
    }
    _coordinator.dispose();
  }
}

final realtimeFinancialSyncServiceProvider =
    Provider<RealtimeFinancialSyncService>((ref) {
  final service = RealtimeFinancialSyncService(ref, ref.read(supabaseProvider));
  ref.listen<int>(pendingSalesRevisionProvider, (_, _) {
    service.emitManualRefresh();
  });
  ref.onDispose(service.dispose);
  return service;
});

final financialRealtimeEventStreamProvider =
    StreamProvider<FinancialRealtimeEvent>((ref) {
  return ref.watch(realtimeFinancialSyncServiceProvider).eventStream;
});

class RealtimeFinancialSyncService {
  RealtimeFinancialSyncService(this._ref, this._client) {
    _channel = _client.channel('public:finanzas_global');
    for (final table in ['pagos_venta', 'pagos_gasto', 'pagos_empleados']) {
      _channel!.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _queueRefresh(),
      );
    }
    _channel!.subscribe();
  }

  final Ref _ref;
  final SupabaseClient _client;
  final _events = StreamController<FinancialRealtimeEvent>.broadcast();
  RealtimeChannel? _channel;
  Timer? _timer;
  bool _disposed = false;

  Stream<FinancialRealtimeEvent> get eventStream => _events.stream;

  void _queueRefresh() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), emitManualRefresh);
  }

  void emitManualRefresh() {
    if (_disposed) return;
    _events.add(const FinancialRealtimeEvent(
      requiereRecargaReportesFinancieros: true,
    ));
    _ref.read(reportesFinancierosRevisionProvider.notifier).state++;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    final channel = _channel;
    if (channel != null) {
      unawaited(_removeChannel(_client, channel));
    }
    unawaited(_events.close());
  }
}

Future<void> _removeChannel(SupabaseClient client, RealtimeChannel channel) async {
  try {
    await client.removeChannel(channel);
  } catch (error) {
    debugPrint('No se pudo cerrar el canal realtime: $error');
  }
}
