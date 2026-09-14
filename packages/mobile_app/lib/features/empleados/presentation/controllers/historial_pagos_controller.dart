import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';

class HistorialPagosState {
  final List<Map<String, dynamic>> pagos;
  final double totalMontoRango;
  final bool isLoading;
  final bool isFetchingMore;
  final bool hasMore;

  HistorialPagosState({
    this.pagos = const [],
    this.totalMontoRango = 0,
    this.isLoading = false,
    this.isFetchingMore = false,
    this.hasMore = true,
  });

  HistorialPagosState copyWith({
    List<Map<String, dynamic>>? pagos,
    double? totalMontoRango,
    bool? isLoading,
    bool? isFetchingMore,
    bool? hasMore,
  }) {
    return HistorialPagosState(
      pagos: pagos ?? this.pagos,
      totalMontoRango: totalMontoRango ?? this.totalMontoRango,
      isLoading: isLoading ?? this.isLoading,
      isFetchingMore: isFetchingMore ?? this.isFetchingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

final historialPagosNotifierProvider =
    StateNotifierProvider<
      HistorialPagosNotifier,
      AsyncValue<HistorialPagosState>
    >((ref) {
      return HistorialPagosNotifier(ref.read(empleadosRepositoryProvider));
    });

class HistorialPagosNotifier
    extends StateNotifier<AsyncValue<HistorialPagosState>> {
  final EmpleadosRepository _repo;
  final int _limit = 20;
  int _offset = 0;

  int? _empleadoId;
  DateTime? _fechaInicio;
  DateTime? _fechaFin;

  HistorialPagosNotifier(this._repo) : super(const AsyncLoading());

  Future<void> loadInitialData({
    int? empleadoId,
    DateTime? fechaInicio,
    DateTime? fechaFin,
  }) async {
    _empleadoId = empleadoId;
    _fechaInicio = fechaInicio;
    _fechaFin = fechaFin;
    _offset = 0;

    state = const AsyncLoading();
    try {
      final pagos = await _repo.obtenerHistorialPagos(
        empleadoId: _empleadoId,
        fechaInicio: _fechaInicio,
        fechaFin: _fechaFin,
        limit: _limit,
        offset: _offset,
      );

      final total = await _repo.obtenerTotalHistorialPagos(
        empleadoId: _empleadoId,
        fechaInicio: _fechaInicio,
        fechaFin: _fechaFin,
      );

      _offset += _limit;

      state = AsyncData(
        HistorialPagosState(
          pagos: pagos,
          totalMontoRango: total,
          isLoading: false,
          isFetchingMore: false,
          hasMore: pagos.length == _limit,
        ),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> loadMore() async {
    final currentState = state.value;
    if (currentState == null ||
        currentState.isFetchingMore ||
        !currentState.hasMore) {
      return;
    }

    state = AsyncData(currentState.copyWith(isFetchingMore: true));

    try {
      final nuevosPagos = await _repo.obtenerHistorialPagos(
        empleadoId: _empleadoId,
        fechaInicio: _fechaInicio,
        fechaFin: _fechaFin,
        limit: _limit,
        offset: _offset,
      );

      if (nuevosPagos.isEmpty) {
        state = AsyncData(
          currentState.copyWith(isFetchingMore: false, hasMore: false),
        );
        return;
      }

      _offset += _limit;

      state = AsyncData(
        currentState.copyWith(
          pagos: [...currentState.pagos, ...nuevosPagos],
          isFetchingMore: false,
          hasMore: nuevosPagos.length == _limit,
        ),
      );
    } catch (e) {
      // Revert fetching more status on error
      state = AsyncData(currentState.copyWith(isFetchingMore: false));
    }
  }

  Future<void> refresh() async {
    await loadInitialData(
      empleadoId: _empleadoId,
      fechaInicio: _fechaInicio,
      fechaFin: _fechaFin,
    );
  }
}
