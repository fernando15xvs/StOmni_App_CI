import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

class FinanzasService {
  FinanzasService(this._supabase);

  final SupabaseClient _supabase;

  static const int _pageSize = 1000;

  Future<List<Map<String, dynamic>>> obtenerMovimientosFinancieros(
    DateTime inicio,
    DateTime fin,
  ) async {
    final startStr = AppTime.toIsoLima(inicio);
    final endStr = AppTime.toIsoLima(fin.add(const Duration(seconds: 1)));

    final resultados = <Map<String, dynamic>>[];
    var offset = 0;

    while (true) {
      final page = await _supabase
          .from('reportes_movimientos_financieros')
          .select()
          .gte('fecha', startStr)
          .lt('fecha', endStr)
          .order('fecha', ascending: false)
          .order('origen', ascending: true)
          .order('origen_id', ascending: false)
          .range(offset, offset + _pageSize - 1);

      final rows = List<Map<String, dynamic>>.from(page);
      resultados.addAll(rows);
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }

    return resultados;
  }

  Future<List<Map<String, dynamic>>> obtenerUltimosMovimientos({
    int limite = 10,
  }) async {
    final response = await _supabase
        .from('reportes_movimientos_financieros')
        .select()
        .order('fecha', ascending: false)
        .order('origen', ascending: true)
        .order('origen_id', ascending: false)
        .limit(limite);

    return List<Map<String, dynamic>>.from(response);
  }
}
