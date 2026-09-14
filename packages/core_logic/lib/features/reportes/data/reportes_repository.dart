import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final finanzasServiceProvider = Provider<FinanzasService>((ref) {
  return FinanzasService(ref.read(supabaseProvider));
});

final reportesRepositoryProvider = Provider<ReportesRepository>((ref) {
  return ReportesRepository(
    ref.read(supabaseProvider),
    ref.read(finanzasServiceProvider),
  );
});

class ReportesRepositorySnapshot {
  final List<Map<String, dynamic>> financieros;
  final List<Map<String, dynamic>> inventario;
  final double totalDescuentos;

  const ReportesRepositorySnapshot({
    required this.financieros,
    required this.inventario,
    required this.totalDescuentos,
  });
}

class ReportesRepository {
  ReportesRepository(this._client, this._finanzasService);

  final SupabaseClient _client;
  final FinanzasService _finanzasService;

  static const int _pageSize = 1000;

  Future<ReportesRepositorySnapshot> cargarPeriodo({
    required DateTime fechaInicio,
    required DateTime fechaFin,
  }) async {
    final resultados = await Future.wait<dynamic>([
      _finanzasService.obtenerMovimientosFinancieros(fechaInicio, fechaFin),
      _cargarInventarioCompleto(fechaInicio, fechaFin),
      _obtenerTotalDescuentos(fechaInicio, fechaFin),
    ]);

    return ReportesRepositorySnapshot(
      financieros: List<Map<String, dynamic>>.from(resultados[0] as List),
      inventario: List<Map<String, dynamic>>.from(resultados[1] as List),
      totalDescuentos: (resultados[2] as num).toDouble(),
    );
  }

  Future<List<Map<String, dynamic>>> _cargarInventarioCompleto(
    DateTime fechaInicio,
    DateTime fechaFin,
  ) async {
    final start = AppTime.toIsoLima(fechaInicio);
    final end = AppTime.toIsoLima(fechaFin.add(const Duration(seconds: 1)));

    final resultados = <Map<String, dynamic>>[];
    var offset = 0;

    while (true) {
      final page = await _client
          .from('inventario_movimientos')
          .select('*, productos(codigo, tipo_venta, cantidad_por_caja)')
          .gte('fecha', start)
          .lt('fecha', end)
          .order('fecha', ascending: false)
          .order('id', ascending: false)
          .range(offset, offset + _pageSize - 1);

      final rows = List<Map<String, dynamic>>.from(page);
      resultados.addAll(rows);
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }

    return resultados;
  }

  Future<double> _obtenerTotalDescuentos(
    DateTime fechaInicio,
    DateTime fechaFin,
  ) async {
    final start = AppTime.toIsoLima(fechaInicio);
    final end = AppTime.toIsoLima(fechaFin.add(const Duration(seconds: 1)));

    var total = 0.0;
    var offset = 0;

    while (true) {
      final page = await _client
          .from('ventas')
          .select('id, descuento_global_monto')
          .gte('fecha', start)
          .lt('fecha', end)
          .neq('estado', 'anulado')
          .order('id', ascending: true)
          .range(offset, offset + _pageSize - 1);

      final rows = List<Map<String, dynamic>>.from(page);
      for (final row in rows) {
        total += (row['descuento_global_monto'] as num?)?.toDouble() ?? 0.0;
      }

      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }

    return total;
  }
}
