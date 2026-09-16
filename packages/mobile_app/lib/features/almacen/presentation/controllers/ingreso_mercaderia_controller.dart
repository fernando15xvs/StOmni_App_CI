import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/inventory_use_case_providers.dart';

class IngresoMercaderiaState {
  final bool guardando;
  final bool exito;
  final String? error;

  const IngresoMercaderiaState({
    this.guardando = false,
    this.exito = false,
    this.error,
  });

  IngresoMercaderiaState copyWith({
    bool? guardando,
    bool? exito,
    String? error,
    bool clearError = false,
    bool clearExito = false,
  }) {
    return IngresoMercaderiaState(
      guardando: guardando ?? this.guardando,
      exito: exito ?? (clearExito ? false : this.exito),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class IngresoMercaderiaNotifier extends StateNotifier<IngresoMercaderiaState> {
  final Ref _ref;

  IngresoMercaderiaNotifier(this._ref) : super(const IngresoMercaderiaState());

  Future<void> registrar({
    required String requestId,
    required int productoId,
    required DateTime fecha,
    required String tipoIngreso,
    required String documento,
    required int? proveedorId,
    required String observaciones,
    required List<Map<String, dynamic>> almacenes,
    required double ingresoCosto,
    required double ingresoPUnit,
    required double ingresoPCaja,
    required double ingresoPCComp,
  }) async {
    state = state.copyWith(guardando: true, clearError: true, clearExito: true);

    try {
      final allocations = almacenes
          .map((warehouse) {
            final rawWarehouseId = warehouse['almacen_id'];
            final rawBaseQuantity = warehouse['cantidad_base'];
            final warehouseId = rawWarehouseId is num
                ? rawWarehouseId.toInt()
                : int.tryParse(rawWarehouseId?.toString() ?? '');
            final baseQuantity = rawBaseQuantity is num
                ? rawBaseQuantity.toDouble()
                : double.tryParse(rawBaseQuantity?.toString() ?? '');
            if (warehouseId == null ||
                warehouseId <= 0 ||
                baseQuantity == null ||
                !baseQuantity.isFinite ||
                baseQuantity <= 0) {
              throw StateError('La distribución por almacén es inválida.');
            }
            return MerchandiseWarehouseAllocation(
              warehouseId: warehouseId,
              baseQuantity: baseQuantity,
            );
          })
          .toList(growable: false);

      await _ref.read(registerMerchandiseEntryUseCaseProvider)(
        MerchandiseEntryCommand(
          requestId: requestId,
          productId: productoId,
          date: fecha,
          entryType: tipoIngreso,
          document: documento,
          supplierId: proveedorId,
          observations: observaciones,
          warehouses: allocations,
          cost: ingresoCosto,
          unitPrice: ingresoPUnit,
          boxPrice: ingresoPCaja,
          comparativeBoxPrice: ingresoPCComp,
        ),
      );

      state = state.copyWith(guardando: false, exito: true);
    } catch (e) {
      state = state.copyWith(guardando: false, error: ErrorMapper.map(e));
    }
  }

  void limpiarExito() {
    state = state.copyWith(clearExito: true);
  }
}

final ingresoMercaderiaNotifierProvider =
    StateNotifierProvider.autoDispose<
      IngresoMercaderiaNotifier,
      IngresoMercaderiaState
    >((ref) => IngresoMercaderiaNotifier(ref));
