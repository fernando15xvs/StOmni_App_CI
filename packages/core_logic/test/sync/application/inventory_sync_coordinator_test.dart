import 'dart:async';

import 'package:core_logic/sync/application/inventory_sync_coordinator.dart';
import 'package:core_logic/sync/application/sync_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Inventory inventory;
  late InventorySyncCoordinator coordinator;
  late List<InventoryRealtimeEvent> events;
  late StreamSubscription<InventoryRealtimeEvent> subscription;

  setUp(() {
    inventory = _Inventory();
    coordinator = InventorySyncCoordinator(
      inventory: inventory,
      debounce: const Duration(hours: 1),
      retryDelay: const Duration(hours: 1),
    );
    events = [];
    subscription = coordinator.events.listen(events.add);
  });

  tearDown(() async {
    coordinator.dispose();
    await subscription.cancel();
  });

  test('deduplica productos y conserva la recarga de Kardex', () async {
    coordinator.productChanged(1);
    coordinator.productChanged(1, affectsLedger: true);
    coordinator.productChanged(2);
    await coordinator.flush();
    await Future<void>.delayed(Duration.zero);
    expect(inventory.ids, [1, 2]);
    expect(events.single.productosActualizados, {1, 2});
    expect(events.single.requiereRecargaKardex, isTrue);
  });

  test(
    'un fallo no impide publicar los otros productos y se reintenta',
    () async {
      inventory.failIds.add(1);
      coordinator.productChanged(1, affectsLedger: true);
      coordinator.productChanged(2);
      await coordinator.flush();
      await Future<void>.delayed(Duration.zero);
      expect(events.single.productosActualizados, {2});
      expect(events.single.requiereRecargaKardex, isFalse);

      inventory.failIds.clear();
      await coordinator.flush();
      await Future<void>.delayed(Duration.zero);
      expect(inventory.ids, [1, 2, 1]);
      expect(events.last.productosActualizados, {1});
      expect(events.last.requiereRecargaKardex, isTrue);
    },
  );

  test('los reintentos automáticos tienen límite', () async {
    inventory.failIds.add(1);
    coordinator.productChanged(1);
    for (var i = 0; i < 5; i++) {
      await coordinator.flush();
    }
    expect(inventory.ids, [1, 1, 1]);
    expect(events, isEmpty);
  });

  test('eventos recibidos durante una operación no se pierden', () async {
    final gate = Completer<void>();
    inventory.productGate = gate.future;
    coordinator.productChanged(1);
    final first = coordinator.flush();
    final second = coordinator.flush();
    coordinator.productChanged(2);
    gate.complete();
    await Future.wait([first, second]);
    await coordinator.flush();
    expect(inventory.ids, [1, 2]);
  });

  test(
    'refresh completo no borra eventos que llegaron mientras esperaba',
    () async {
      final gate = Completer<void>();
      inventory.fullGate = gate.future;
      final refresh = coordinator.refreshAll();
      coordinator.productChanged(7);
      gate.complete();
      await refresh;
      await coordinator.flush();
      expect(inventory.ids, [7]);
      expect(inventory.fullRefreshes, 1);
    },
  );

  test(
    'dispose durante una petición no publica ni programa más trabajo',
    () async {
      final gate = Completer<void>();
      inventory.productGate = gate.future;
      coordinator.productChanged(1);
      final pending = coordinator.flush();
      coordinator.dispose();
      gate.complete();
      await pending;
      coordinator.productChanged(2);
      await coordinator.flush();
      expect(inventory.ids, [1]);
      expect(events, isEmpty);
    },
  );
}

class _Inventory implements InventorySyncAdapter {
  final ids = <int>[];
  final failIds = <int>{};
  Future<void>? productGate;
  Future<void>? fullGate;
  int fullRefreshes = 0;

  @override
  Future<void> sincronizarProducto(int productoId) async {
    ids.add(productoId);
    if (productGate != null) await productGate;
    if (failIds.contains(productoId))
      throw StateError('temporarily unavailable');
  }

  @override
  Future<void> sincronizarTodo({bool propagarError = false}) async {
    fullRefreshes++;
    if (fullGate != null) await fullGate;
  }
}
