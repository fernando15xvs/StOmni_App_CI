import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

class ReportesParams {
  final DateTime fechaInicio;
  final DateTime fechaFin;

  ReportesParams(this.fechaInicio, this.fechaFin);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReportesParams &&
          runtimeType == other.runtimeType &&
          fechaInicio == other.fechaInicio &&
          fechaFin == other.fechaFin;

  @override
  int get hashCode => fechaInicio.hashCode ^ fechaFin.hashCode;
}

/// Estado de compatibilidad de la UI histórica.
///
/// La fuente de verdad ya es [ReportingSnapshot]; estos mapas sólo preservan
/// temporalmente la pantalla existente mientras se retira su parsing legacy.
class ReportesData {
  final List<Map<String, dynamic>> financieros;
  final List<Map<String, dynamic>> inventario;
  final double totalDescuentos;
  final bool isLoading;
  final bool isSilentSyncing;
  final String? error;

  ReportesData({
    this.financieros = const [],
    this.inventario = const [],
    this.totalDescuentos = 0.0,
    this.isLoading = false,
    this.isSilentSyncing = false,
    this.error,
  });

  ReportesData copyWith({
    List<Map<String, dynamic>>? financieros,
    List<Map<String, dynamic>>? inventario,
    double? totalDescuentos,
    bool? isLoading,
    bool? isSilentSyncing,
    String? error,
  }) {
    return ReportesData(
      financieros: financieros ?? this.financieros,
      inventario: inventario ?? this.inventario,
      totalDescuentos: totalDescuentos ?? this.totalDescuentos,
      isLoading: isLoading ?? this.isLoading,
      isSilentSyncing: isSilentSyncing ?? this.isSilentSyncing,
      error: error,
    );
  }
}

class _ReportesLoadRequest {
  final ReportesParams params;
  final int revisionInventario;
  final int revisionFinanciera;
  final bool silent;
  final bool force;

  const _ReportesLoadRequest({
    required this.params,
    required this.revisionInventario,
    required this.revisionFinanciera,
    required this.silent,
    required this.force,
  });
}

class ReportesNotifier extends StateNotifier<ReportesData> {
  ReportesNotifier(this._useCase) : super(ReportesData());

  final LoadReportingSnapshotUseCase _useCase;

  ReportesParams? _lastParams;
  int _ultimaRevisionInventarioCargada = -1;
  int _ultimaRevisionFinancieraCargada = -1;
  bool _cargandoActualmente = false;
  bool _hasLoaded = false;
  _ReportesLoadRequest? _pendiente;

  Future<void> cargarDatos(
    ReportesParams params,
    int revisionInventario,
    int revisionFinanciera, {
    bool silent = false,
    bool force = false,
  }) async {
    final request = _ReportesLoadRequest(
      params: params,
      revisionInventario: revisionInventario,
      revisionFinanciera: revisionFinanciera,
      silent: silent,
      force: force,
    );

    if (_cargandoActualmente) {
      _pendiente = request;
      return;
    }

    var actual = request;
    while (true) {
      await _ejecutarCarga(actual);
      final siguiente = _pendiente;
      _pendiente = null;
      if (siguiente == null) break;
      actual = siguiente;
    }
  }

  Future<void> _ejecutarCarga(_ReportesLoadRequest request) async {
    final cambioRango = _lastParams != request.params;
    final necesitaCargar =
        request.force ||
        !_hasLoaded ||
        cambioRango ||
        request.revisionInventario != _ultimaRevisionInventarioCargada ||
        request.revisionFinanciera != _ultimaRevisionFinancieraCargada;

    if (!necesitaCargar) return;
    _cargandoActualmente = true;

    final conservaDatosPrevios =
        request.silent &&
        !cambioRango &&
        (state.financieros.isNotEmpty || state.inventario.isNotEmpty);

    if (conservaDatosPrevios) {
      state = state.copyWith(isSilentSyncing: true, error: null);
    } else {
      state = state.copyWith(isLoading: true, isSilentSyncing: false, error: null);
    }

    try {
      final snapshot = await _useCase.execute(
        start: request.params.fechaInicio,
        end: request.params.fechaFin,
      );

      state = state.copyWith(
        financieros: snapshot.financialMovements
            .map(_financialCompatibilityMap)
            .toList(growable: false),
        inventario: snapshot.inventoryMovements
            .map(_inventoryCompatibilityMap)
            .toList(growable: false),
        totalDescuentos: snapshot.totalDiscounts,
        isLoading: false,
        isSilentSyncing: false,
        error: null,
      );

      _lastParams = request.params;
      _hasLoaded = true;
      _ultimaRevisionInventarioCargada = request.revisionInventario;
      _ultimaRevisionFinancieraCargada = request.revisionFinanciera;
    } catch (e) {
      debugPrint('Error ReportesNotifier: $e');
      final mensaje = ErrorMapper.isConnectionError(e)
          ? 'No pudimos actualizar los reportes. Comprueba tu conexión a Internet e inténtalo nuevamente.'
          : ErrorMapper.map(e);

      if (cambioRango || !_hasLoaded) {
        state = ReportesData(
          isLoading: false,
          isSilentSyncing: false,
          error: mensaje,
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          isSilentSyncing: false,
          error: mensaje,
        );
      }
    } finally {
      _cargandoActualmente = false;
    }
  }

  static Map<String, dynamic> _financialCompatibilityMap(
    FinancialMovementRecord movement,
  ) {
    return <String, dynamic>{
      'tipo': movement.type == FinancialMovementType.income ? 'ingreso' : 'egreso',
      'monto': movement.amount,
      'descripcion': movement.description,
      'fecha': movement.date.toIso8601String(),
      'venta_id': movement.saleId,
      'gasto_id': movement.expenseId,
      'pago_empleado_id': movement.employeePaymentId,
      'metodo_pago': movement.paymentMethod,
    };
  }

  static Map<String, dynamic> _inventoryCompatibilityMap(
    InventoryMovementRecord movement,
  ) {
    return <String, dynamic>{
      'producto_id': movement.productId,
      'producto_nombre': movement.productName,
      'almacen_nombre': movement.warehouseName,
      'tipo': movement.movementType,
      'fecha': movement.date.toIso8601String(),
      'cantidad': movement.quantity,
      'ingreso_cant': movement.entryQuantity,
      'salida_cant': movement.exitQuantity,
      'observaciones': movement.observations,
      'unidad_label': movement.unitLabel,
      'tipo_venta_snapshot': movement.saleUnitTypeSnapshot,
      'unidad_base_snapshot': movement.baseUnitSnapshot,
      'pcs': movement.unitsPerPackageSnapshot,
      'productos': <String, dynamic>{
        'tipo_venta': movement.saleUnitType,
        'cantidad_por_caja': movement.unitsPerPackage,
      },
    };
  }
}

final reportesUseCaseProvider = Provider<LoadReportingSnapshotUseCase>((ref) {
  return LoadReportingSnapshotUseCase(
    gateway: SupabaseReportingGateway(ref.read(supabaseProvider)),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final reportesProvider = StateNotifierProvider<ReportesNotifier, ReportesData>((ref) {
  return ReportesNotifier(ref.watch(reportesUseCaseProvider));
});
