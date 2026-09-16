import 'package:mobile_app/platform/realtime/realtime_sync_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/global_date_filter.dart';

const Object _kardexNoValue = Object();

class KardexState {
  final bool cargando;
  final bool cargandoMas;
  final bool hasMore;
  final int offset;
  final List<Map<String, dynamic>> kardexRaw;
  final List<Map<String, dynamic>> kardexVisible;
  final GlobalDateFilterState dateFilter;
  final int? productoIdFiltro;
  final String productoBuscado;
  final String? error;

  KardexState({
    this.cargando = false,
    this.cargandoMas = false,
    this.hasMore = true,
    this.offset = 0,
    this.kardexRaw = const [],
    this.kardexVisible = const [],
    required this.dateFilter,
    this.productoIdFiltro,
    this.productoBuscado = '',
    this.error,
  });

  KardexState copyWith({
    bool? cargando,
    bool? cargandoMas,
    bool? hasMore,
    int? offset,
    List<Map<String, dynamic>>? kardexRaw,
    List<Map<String, dynamic>>? kardexVisible,
    GlobalDateFilterState? dateFilter,
    Object? productoIdFiltro = _kardexNoValue,
    String? productoBuscado,
    Object? error = _kardexNoValue,
  }) {
    return KardexState(
      cargando: cargando ?? this.cargando,
      cargandoMas: cargandoMas ?? this.cargandoMas,
      hasMore: hasMore ?? this.hasMore,
      offset: offset ?? this.offset,
      kardexRaw: kardexRaw ?? this.kardexRaw,
      kardexVisible: kardexVisible ?? this.kardexVisible,
      dateFilter: dateFilter ?? this.dateFilter,
      productoIdFiltro: identical(productoIdFiltro, _kardexNoValue)
          ? this.productoIdFiltro
          : productoIdFiltro as int?,
      productoBuscado: productoBuscado ?? this.productoBuscado,
      error: identical(error, _kardexNoValue) ? this.error : error as String?,
    );
  }
}

class KardexNotifier extends StateNotifier<KardexState> {
  final Ref _ref;
  final KardexRepository _repository;

  KardexNotifier(this._ref, this._repository)
    : super(KardexState(dateFilter: GlobalDateFilterState()));

  static const int _limit = 50;

  String get _fechaInicio => AppTime.toIsoLima(state.dateFilter.fechaInicio);

  String get _fechaFin => AppTime.toIsoLima(
    state.dateFilter.fechaFin.add(const Duration(seconds: 1)),
  );

  Future<List<Map<String, dynamic>>> _consultarPagina(int offset) async {
    if (!AppRoles.isAdmin(_ref.read(rolProvider))) {
      throw StateError('Solo el administrador puede consultar el Kardex.');
    }

    return _repository.consultarPagina(
      fechaInicio: _fechaInicio,
      fechaFin: _fechaFin,
      limit: _limit,
      offset: offset,
      productoId: state.productoIdFiltro,
    );
  }

  void filtrarKardex(String query, {bool exactMatch = false}) {
    final texto = query.trim().toLowerCase();
    final visible = texto.isEmpty
        ? List<Map<String, dynamic>>.from(state.kardexRaw)
        : state.kardexRaw.where((item) {
            final nombre = (item['producto_nombre'] ?? '')
                .toString()
                .toLowerCase();
            return exactMatch ? nombre == texto : nombre.contains(texto);
          }).toList();

    state = state.copyWith(productoBuscado: query, kardexVisible: visible);
  }

  Future<void> seleccionarProducto(int productoId, String nombre) async {
    state = state.copyWith(
      productoIdFiltro: productoId,
      productoBuscado: nombre,
    );
    await cargarKardex();
  }

  Future<void> limpiarProducto() async {
    state = state.copyWith(productoIdFiltro: null, productoBuscado: '');
    await cargarKardex();
  }

  void updateDateFilter(GlobalDateFilterState newFilter) {
    state = state.copyWith(dateFilter: newFilter);
    cargarKardex();
  }

  Future<void> cargarKardex({bool silent = false}) async {
    if (state.cargando || state.cargandoMas) return;

    state = state.copyWith(
      cargando: !silent || state.kardexRaw.isEmpty,
      error: null,
    );

    try {
      final firstPage = await _consultarPagina(0);
      state = state.copyWith(
        cargando: false,
        cargandoMas: false,
        kardexRaw: firstPage,
        kardexVisible: firstPage,
        hasMore: firstPage.length == _limit,
        offset: 0,
        error: null,
      );
    } catch (e) {
      debugPrint('Error cargando Kardex: $e');
      state = state.copyWith(
        cargando: false,
        cargandoMas: false,
        error: e.toString(),
      );
    }
  }

  Future<void> cargarNuevosMovimientosSilencioso() async {
    if (state.cargando || state.cargandoMas) return;
    if (state.kardexRaw.isEmpty) {
      await cargarKardex(silent: true);
      return;
    }

    final maxId = state.kardexRaw.fold<int>(0, (maximo, item) {
      final id = (item['id'] as num?)?.toInt() ?? 0;
      return id > maximo ? id : maximo;
    });

    try {
      final nuevos = await _repository.consultarNuevosMovimientos(
        maxId: maxId,
        fechaInicio: _fechaInicio,
        fechaFin: _fechaFin,
        productoId: state.productoIdFiltro,
      );

      if (nuevos.isEmpty) return;

      final porId = <int, Map<String, dynamic>>{};
      for (final item in [...nuevos, ...state.kardexRaw]) {
        final id = (item['id'] as num?)?.toInt() ?? 0;
        if (id > 0) porId[id] = item;
      }

      final combinados = porId.values.toList()
        ..sort((a, b) {
          final fechaA =
              DateTime.tryParse(a['fecha']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final fechaB =
              DateTime.tryParse(b['fecha']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final cmpFecha = fechaB.compareTo(fechaA);
          if (cmpFecha != 0) return cmpFecha;
          final idA = (a['id'] as num?)?.toInt() ?? 0;
          final idB = (b['id'] as num?)?.toInt() ?? 0;
          return idB.compareTo(idA);
        });

      state = state.copyWith(kardexRaw: combinados, kardexVisible: combinados);
    } catch (e) {
      debugPrint('Error recargando nuevos movimientos: $e');
    }
  }

  Future<void> cargarMasKardex() async {
    if (state.cargando || state.cargandoMas || !state.hasMore) return;

    state = state.copyWith(cargandoMas: true, error: null);
    final nextOffset = state.offset + _limit;

    try {
      final page = await _consultarPagina(nextOffset);
      final acumulado = <Map<String, dynamic>>[...state.kardexRaw, ...page];

      state = state.copyWith(
        cargandoMas: false,
        kardexRaw: acumulado,
        kardexVisible: acumulado,
        hasMore: page.length == _limit,
        offset: nextOffset,
        error: null,
      );
    } catch (e) {
      debugPrint('Error cargando más Kardex: $e');
      state = state.copyWith(cargandoMas: false, error: e.toString());
    }
  }
}

final kardexProvider = StateNotifierProvider<KardexNotifier, KardexState>((
  ref,
) {
  final notifier = KardexNotifier(ref, ref.read(kardexRepositoryProvider));

  ref.listen(inventoryRealtimeEventStreamProvider, (previous, next) {
    if (next.hasValue && next.value!.requiereRecargaKardex) {
      notifier.cargarNuevosMovimientosSilencioso();
    }
  });

  return notifier;
});
