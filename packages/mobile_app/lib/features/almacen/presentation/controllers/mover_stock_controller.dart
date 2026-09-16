import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../home/home_notifier.dart';
import '../providers/inventory_use_case_providers.dart';

class MoverStockState {
  final bool guardando;
  final StockMovementResult? exito;
  final String? error;

  const MoverStockState({this.guardando = false, this.exito, this.error});

  MoverStockState copyWith({
    bool? guardando,
    StockMovementResult? exito,
    String? error,
    bool clearExito = false,
    bool clearError = false,
  }) {
    return MoverStockState(
      guardando: guardando ?? this.guardando,
      exito: clearExito ? null : (exito ?? this.exito),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class MoverStockNotifier extends StateNotifier<MoverStockState> {
  final Ref _ref;

  MoverStockNotifier(this._ref) : super(const MoverStockState());

  Future<void> registrarMovimiento({
    required String requestId,
    required int productoId,
    required double cantidad,
    required int origenId,
    required int? destinoId,
    required bool esMerma,
    required String motivo,
  }) async {
    state = state.copyWith(guardando: true, clearExito: true, clearError: true);

    try {
      final result = await _ref.read(registerStockMovementUseCaseProvider)(
        RegisterStockMovementCommand(
          requestId: requestId,
          productId: productoId,
          quantity: cantidad,
          sourceWarehouseId: origenId,
          destinationWarehouseId: destinoId,
          isWaste: esMerma,
          reason: motivo,
        ),
      );

      triggerHomeRefresh();
      state = state.copyWith(guardando: false, exito: result);
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      final String errorMessage;
      if (ErrorMapper.isConnectionError(e)) {
        errorMessage =
            'No hay conexión a Internet. La operación fue cancelada de forma segura; comprueba tu conexión e inténtalo nuevamente.';
      } else if (errorStr.contains('stock insuficiente')) {
        errorMessage =
            'El stock origen es insuficiente o ha cambiado recientemente.';
      } else {
        errorMessage = ErrorMapper.map(e);
      }
      state = state.copyWith(guardando: false, error: errorMessage);
    }
  }

  void limpiarExito() {
    state = state.copyWith(clearExito: true);
  }
}

final moverStockNotifierProvider =
    StateNotifierProvider.autoDispose<MoverStockNotifier, MoverStockState>(
      (ref) => MoverStockNotifier(ref),
    );
