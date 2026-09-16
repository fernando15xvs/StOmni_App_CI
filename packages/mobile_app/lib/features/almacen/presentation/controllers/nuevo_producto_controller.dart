import 'dart:typed_data';

import 'package:core_logic/core_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/search_revision_provider.dart';
import '../providers/inventory_use_case_providers.dart';
import '../providers/product_form_catalog_use_case_provider.dart';
import '../providers/save_product_use_case_provider.dart';

class NuevoProductoState {
  final bool cargando;
  final bool guardando;
  final List<ProductWarehouseOption> warehouseOptions;
  final List<ProductSupplierOption> supplierOptions;
  final String? error;

  NuevoProductoState({
    this.cargando = false,
    this.guardando = false,
    this.warehouseOptions = const [],
    this.supplierOptions = const [],
    this.error,
  });

  /// Compatibilidad temporal con la pantalla actual mientras se elimina el
  /// uso de Map<String, dynamic> de la presentación móvil.
  List<Map<String, dynamic>> get almacenes => warehouseOptions
      .map((warehouse) => warehouse.toLegacyMap())
      .toList(growable: false);

  /// Compatibilidad temporal con la pantalla actual mientras se elimina el
  /// uso de Map<String, dynamic> de la presentación móvil.
  List<Map<String, dynamic>> get proveedores => supplierOptions
      .map((supplier) => supplier.toLegacyMap())
      .toList(growable: false);

  NuevoProductoState copyWith({
    bool? cargando,
    bool? guardando,
    List<ProductWarehouseOption>? warehouseOptions,
    List<ProductSupplierOption>? supplierOptions,
    String? error,
  }) {
    return NuevoProductoState(
      cargando: cargando ?? this.cargando,
      guardando: guardando ?? this.guardando,
      warehouseOptions: warehouseOptions ?? this.warehouseOptions,
      supplierOptions: supplierOptions ?? this.supplierOptions,
      error: error,
    );
  }
}

class NuevoProductoController extends StateNotifier<NuevoProductoState> {
  NuevoProductoController(this.ref) : super(NuevoProductoState());

  final Ref ref;
  String? _currentRequestId;

  Future<void> inicializarDatos() async {
    state = state.copyWith(cargando: true, error: null);
    try {
      final catalog = await ref
          .read(loadProductFormCatalogUseCaseProvider)
          .execute();

      state = state.copyWith(
        cargando: false,
        warehouseOptions: catalog.warehouses,
        supplierOptions: catalog.suppliers,
      );
    } catch (e) {
      debugPrint('Error en inicialización de producto: $e');
      state = state.copyWith(cargando: false, error: ErrorMapper.map(e));
    }
  }

  Future<bool> guardarProducto({
    required Map<String, dynamic>? productoEditar,
    required String codigo,
    required String nombre,
    required double precioUnidad,
    required double precioCaja,
    required double precioCompra,
    required int pcs,
    required SaleUnitType tipoVenta,
    required int stockMinimo,
    required String? proveedorSeleccionadoId,
    required bool permitirSinStock,
    required Uint8List? imagenNuevaBytes,
    required String? urlImagenExistente,
    required Map<int, int> cajasPorAlmacen,
    required Map<int, int> unidadesPorAlmacen,
    bool actualizarMovimientosApertura = false,
  }) async {
    state = state.copyWith(guardando: true, error: null);

    final useCase = ref.read(saveProductUseCaseProvider);
    _currentRequestId ??= useCase.createRequestId();

    try {
      final currentId = productoEditar == null
          ? null
          : (productoEditar['id'] as num).toInt();
      final supplierId = proveedorSeleccionadoId == null
          ? null
          : int.tryParse(proveedorSeleccionadoId);
      final warehouseIds = state.warehouseOptions
          .map((warehouse) => warehouse.id)
          .toList(growable: false);

      final result = await useCase.execute(
        SaveProductCommand(
          requestId: _currentRequestId!,
          productId: currentId,
          code: codigo,
          name: nombre,
          unitPrice: precioUnidad,
          packageBasePrice: precioCaja,
          purchasePrice: precioCompra,
          unitsPerPackage: pcs,
          saleUnitType: tipoVenta,
          minimumStock: stockMinimo,
          supplierId: supplierId,
          allowWithoutStock: permitirSinStock,
          newImageBytes: imagenNuevaBytes,
          existingImageUrl: urlImagenExistente,
          warehouseIds: warehouseIds,
          boxesByWarehouse: cajasPorAlmacen,
          baseUnitsByWarehouse: unidadesPorAlmacen,
          updateOpeningMovements: actualizarMovimientosApertura,
        ),
      );

      if (result.created) {
        ref.read(productSearchRevisionProvider.notifier).state++;
      }

      _currentRequestId = null;
      state = state.copyWith(guardando: false, error: null);
      return true;
    } catch (e) {
      debugPrint('Error guardando producto: $e');
      state = state.copyWith(guardando: false, error: ErrorMapper.map(e));
      return false;
    }
  }

  /// Compatibilidad temporal: el caso de uso ya devuelve un resultado tipado,
  /// pero esta pantalla todavía consume el formato histórico basado en mapas.
  Future<Map<String, dynamic>> evaluarHistorialApertura(int productoId) async {
    try {
      final evaluation = await ref
          .read(productLifecycleUseCaseProvider)
          .evaluateDeletion(productoId);
      return <String, dynamic>{
        'movimientos_apertura': evaluation.openingMovementCount,
        'puede_actualizar_apertura': evaluation.canUpdateOpening,
      };
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}

final nuevoProductoControllerProvider =
    StateNotifierProvider.autoDispose<
      NuevoProductoController,
      NuevoProductoState
    >((ref) {
      return NuevoProductoController(ref);
    });
