import 'package:mobile_app/platform/realtime/realtime_sync_service.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_app/features/shared/providers/search_revision_provider.dart';
import 'package:mobile_app/home/home_notifier.dart';

import '../providers/inventory_use_case_providers.dart';

Map<String, dynamic> _legacyInventoryProduct(InventoryCatalogItem item) {
  final product = item.product;
  final code = product.codigo?.trim() ?? '';
  final name = product.nombre.trim();
  return <String, dynamic>{
    ...ProductoMapper.encode(product),
    'activo': item.active,
    '_totalStock': item.totalStock,
    '_marcaNombre': item.brandName,
    '_nombreLower': name.toLowerCase(),
    '_codigoLower': code.toLowerCase(),
    '_busquedaLower': item.searchText,
    '_precioDouble': item.mainPrice,
  };
}

Map<String, dynamic> _legacyInventoryWarehouse(InventoryWarehouseRecord warehouse) {
  return <String, dynamic>{
    'id': warehouse.id,
    'nombre': warehouse.name,
    'activo': warehouse.active,
    'direccion': warehouse.address,
    'ubigeo': warehouse.ubigeo,
    'departamento': warehouse.department,
    'provincia': warehouse.province,
    'distrito': warehouse.district,
    'cod_local': warehouse.localCode,
    'referencia': warehouse.reference,
  };
}

class AlmacenState {
  final List<InventoryCatalogItem> catalogProducts;
  final List<InventoryWarehouseRecord> warehouseRecords;
  final Map<int, String> mapaMarcas;
  final bool modoOffline;

  AlmacenState({
    this.catalogProducts = const [],
    this.warehouseRecords = const [],
    this.mapaMarcas = const {},
    this.modoOffline = false,
  });

  /// Compatibilidad temporal para widgets/exportadores todavía basados en mapas.
  List<Map<String, dynamic>> get productosCompletos => catalogProducts
      .map(_legacyInventoryProduct)
      .toList(growable: false);

  /// Compatibilidad temporal para widgets/exportadores todavía basados en mapas.
  List<Map<String, dynamic>> get configAlmacenes => warehouseRecords
      .map(_legacyInventoryWarehouse)
      .toList(growable: false);

  AlmacenState copyWith({
    List<InventoryCatalogItem>? catalogProducts,
    List<InventoryWarehouseRecord>? warehouseRecords,
    Map<int, String>? mapaMarcas,
    bool? modoOffline,
  }) {
    return AlmacenState(
      catalogProducts: catalogProducts ?? this.catalogProducts,
      warehouseRecords: warehouseRecords ?? this.warehouseRecords,
      mapaMarcas: mapaMarcas ?? this.mapaMarcas,
      modoOffline: modoOffline ?? this.modoOffline,
    );
  }
}

class AlmacenNotifier extends AsyncNotifier<AlmacenState> {
  @override
  Future<AlmacenState> build() async {
    ref.listen(inventoryRealtimeEventStreamProvider, (previous, next) {
      if (next.hasValue) {
        recargarLocalSilencioso();
        ref.read(productSearchRevisionProvider.notifier).state++;
      }
    });

    return _cargarDatosIniciales();
  }

  Future<void> recargarLocalSilencioso() async {
    if (!state.hasValue) return;

    final products = await ref
        .read(inventoryCatalogUseCaseProvider)
        .reloadLocalProducts(brands: state.value!.mapaMarcas);

    state = AsyncValue.data(
      state.value!.copyWith(catalogProducts: products),
    );
  }

  Future<AlmacenState> _cargarDatosIniciales() async {
    final snapshot = await ref.read(inventoryCatalogUseCaseProvider).loadInitial();
    return _stateFromSnapshot(snapshot);
  }

  AlmacenState _stateFromSnapshot(InventoryCatalogSnapshot snapshot) {
    return AlmacenState(
      catalogProducts: snapshot.products,
      warehouseRecords: snapshot.warehouses,
      mapaMarcas: snapshot.brands,
      modoOffline: snapshot.offline,
    );
  }

  Future<void> recargar() async {
    if (!state.hasValue) {
      state = const AsyncValue.loading();
    }
    final newState = await AsyncValue.guard(() => _cargarDatosIniciales());
    state = newState;
  }

  Future<void> forzarActualizacionOnline() async {
    final estadoAnterior = state.value;
    if (estadoAnterior == null) {
      state = const AsyncValue.loading();
    }

    try {
      final snapshot = await ref
          .read(inventoryCatalogUseCaseProvider)
          .forceOnlineRefresh();
      state = AsyncValue.data(_stateFromSnapshot(snapshot));
    } catch (e) {
      if (estadoAnterior != null) {
        state = AsyncValue.data(estadoAnterior.copyWith(modoOffline: true));
      }
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> _refrescarDespuesDeMutacion() async {
    try {
      await forzarActualizacionOnline();
    } catch (_) {
      // La mutación ya fue confirmada. Realtime o la siguiente carga normal
      // terminarán de refrescar el snapshot cuando vuelva el servidor.
    }
    triggerHomeRefresh();
  }

  Future<Map<String, dynamic>> evaluarEliminacionProducto(
    int productoId,
  ) async {
    final evaluation = await ref
        .read(productLifecycleUseCaseProvider)
        .evaluateDeletion(productoId);
    return <String, dynamic>{
      'movimientos_apertura': evaluation.openingMovementCount,
      'puede_actualizar_apertura': evaluation.canUpdateOpening,
    };
  }

  Future<void> desactivarProducto(int productoId) async {
    try {
      await ref.read(productLifecycleUseCaseProvider).deactivate(
            productoId,
            offline: state.value?.modoOffline ?? false,
          );
    } on ProductLifecycleOfflineException catch (e) {
      throw UserFacingException(e.message);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
    await _refrescarDespuesDeMutacion();
  }

  Future<void> eliminarProductoDefinitivamente(int productoId) async {
    try {
      await ref.read(productLifecycleUseCaseProvider).deletePermanently(
            productoId,
            offline: state.value?.modoOffline ?? false,
          );
    } on ProductLifecycleOfflineException catch (e) {
      throw UserFacingException(e.message);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
    await _refrescarDespuesDeMutacion();
  }

  Future<void> reactivarProducto(int productoId) async {
    try {
      await ref
          .read(productLifecycleUseCaseProvider)
          .reactivate(productoId);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
    ref.invalidate(productosInactivosFutureProvider);
    await forzarActualizacionOnline().catchError((_) {});
    triggerHomeRefresh();
  }
}

final almacenNotifierProvider =
    AsyncNotifierProvider<AlmacenNotifier, AlmacenState>(
      () => AlmacenNotifier(),
    );

final almacenBusquedaProvider = StateProvider<String>((ref) => '');
final almacenOrdenarPorProvider = StateProvider<String>((ref) => 'nombre');
final almacenOrdenAscendenteProvider = StateProvider<bool>((ref) => true);

InventorySortField _inventorySortField(String value) {
  return switch (value) {
    'stock' => InventorySortField.stock,
    'precio' => InventorySortField.price,
    _ => InventorySortField.name,
  };
}

final almacenFiltradoProvider =
    Provider.family<AsyncValue<List<Map<String, dynamic>>>, bool>((
      ref,
      soloStockBajo,
    ) {
      final state = ref.watch(almacenNotifierProvider);

      return state.whenData((almacenState) {
        final filtered = ref.watch(inventoryCatalogUseCaseProvider).filterAndSort(
              products: almacenState.catalogProducts,
              query: ref.watch(almacenBusquedaProvider),
              lowStockOnly: soloStockBajo,
              sortBy: _inventorySortField(
                ref.watch(almacenOrdenarPorProvider),
              ),
              ascending: ref.watch(almacenOrdenAscendenteProvider),
            );
        return filtered.map(_legacyInventoryProduct).toList(growable: false);
      });
    });

final _productosInactivosCatalogFutureProvider =
    FutureProvider.autoDispose<List<InventoryCatalogItem>>((ref) {
      return ref.watch(inventoryCatalogUseCaseProvider).loadInactiveProducts();
    });

final productosInactivosFutureProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final items = await ref.watch(_productosInactivosCatalogFutureProvider.future);
      return items.map(_legacyInventoryProduct).toList(growable: false);
    });

final productosInactivosFiltradoProvider =
    Provider.autoDispose<AsyncValue<List<Map<String, dynamic>>>>((ref) {
      final asyncData = ref.watch(_productosInactivosCatalogFutureProvider);
      return asyncData.whenData((inactivos) {
        final filtered = ref.watch(inventoryCatalogUseCaseProvider).filterAndSort(
              products: inactivos,
              query: ref.watch(almacenBusquedaProvider),
              sortBy: _inventorySortField(
                ref.watch(almacenOrdenarPorProvider),
              ),
              ascending: ref.watch(almacenOrdenAscendenteProvider),
            );
        return filtered.map(_legacyInventoryProduct).toList(growable: false);
      });
    });
