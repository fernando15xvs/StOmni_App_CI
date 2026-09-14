import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final balanceRepositoryProvider = Provider<BalanceRepository>((ref) {
  return BalanceRepository(ref.read(supabaseProvider));
});

class BalanceRepository {
  final SupabaseClient _client;

  BalanceRepository(this._client);

  Future<Map<String, dynamic>> getDashboardSummary(
    DateTime inicio,
    DateTime fin,
  ) async {
    final start = AppTime.toIsoLima(inicio);
    final end = AppTime.toIsoLima(fin);
    return await _client.rpc(
      'get_dashboard_summary',
      params: {'inicio': start, 'fin': end},
    );
  }

  Future<List<Map<String, dynamic>>> getMovimientos(
    String tipo,
    DateTime inicio,
    DateTime fin,
  ) async {
    final start = AppTime.toIsoLima(inicio);
    final end = AppTime.toIsoLima(fin);

    final data = await _client
        .from('movimientos')
        .select(
          'id, tipo, monto, descripcion, fecha, metodo, venta_id, gasto_id, pago_empleado_id, organization_id, cash_register_id, cash_session_id',
        )
        .gte('fecha', start)
        .lt('fecha', end)
        .eq('tipo', tipo)
        .order('fecha', ascending: false);

    return List<Map<String, dynamic>>.from(data);
  }

  Future<List<Map<String, dynamic>>> getMovimientosByFechas(
    DateTime inicio,
    DateTime fin,
  ) async {
    final start = AppTime.toIsoLima(inicio);
    final end = AppTime.toIsoLima(fin);

    final data = await _client
        .from('movimientos')
        .select('id, tipo, monto, descripcion, fecha, metodo, cash_session_id')
        .gte('fecha', start)
        .lte('fecha', end)
        .ilike('metodo', '%efectivo%')
        .eq('afecta_caja_chica', true)
        .order('fecha', ascending: true);

    return List<Map<String, dynamic>>.from(data);
  }

  Future<List<Map<String, dynamic>>> getVentasParaDescuento(
    DateTime inicio,
    DateTime fin,
  ) async {
    final start = AppTime.toIsoLima(inicio);
    final end = AppTime.toIsoLima(fin);

    final data = await _client
        .from('ventas')
        .select('descuento_global_monto')
        .gte('fecha', start)
        .lt('fecha', end)
        .neq('estado', 'anulado');

    return List<Map<String, dynamic>>.from(data);
  }

  // ==========================================
  // CAJA CHICA / CASH REGISTER
  // ==========================================

  Future<dynamic> getEstadoCajaChica() async {
    return await _client.rpc('get_estado_caja_chica');
  }

  Future<List<Map<String, dynamic>>> getMovimientosCajaAbierta(
    String fechaApertura, {
    String? sessionId,
  }) async {
    var query = _client
        .from('movimientos')
        .select(
          'id, tipo, monto, descripcion, fecha, metodo, cash_register_id, cash_session_id',
        )
        .ilike('metodo', '%efectivo%')
        .eq('afecta_caja_chica', true);

    if (sessionId != null && sessionId.isNotEmpty) {
      query = query.eq('cash_session_id', sessionId);
    } else {
      // Compatibilidad temporal con consumidores que todavía sólo conservan la
      // fecha de apertura. La UI nueva debe preferir sessionId.
      query = query.gte('fecha', fechaApertura);
    }

    final data = await query.order('fecha', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  Future<void> abrirCaja(
    double montoApertura, {
    String? cashRegisterId,
  }) async {
    await _client.from('sesiones_caja').insert({
      'monto_apertura': montoApertura,
      'usuario_id': _client.auth.currentUser?.id,
      'fecha_apertura': AppTime.nowIso(),
      if (cashRegisterId != null && cashRegisterId.isNotEmpty)
        'cash_register_id': cashRegisterId,
    });
  }

  Future<void> cerrarCaja({
    required String sesionId,
    required String fechaApertura,
    required double montoApertura,
    required double esperado,
    required double real,
    String? observaciones,
  }) async {
    final sesionActualizada = {
      'fecha_cierre': AppTime.nowIso(),
      'monto_cierre_esperado': esperado,
      'monto_cierre_real': real,
      'estado': 'CERRADA',
      'observaciones': observaciones,
    };

    await _client
        .from('sesiones_caja')
        .update(sesionActualizada)
        .eq('id', sesionId);
  }

  // ==========================================
  // HISTORIAL CAJA
  // ==========================================

  Future<List<Map<String, dynamic>>> getHistorialCaja(
    DateTime? desde,
    DateTime? hasta,
  ) async {
    var query = _client
        .from('sesiones_caja')
        .select(
          'id, branch_id, cash_register_id, fecha_apertura, fecha_cierre, monto_apertura, monto_cierre_esperado, monto_cierre_real, observaciones, estado',
        )
        .eq('estado', 'CERRADA');

    if (desde != null) {
      query = query.gte('fecha_apertura', AppTime.toIsoLima(desde));
    }
    if (hasta != null) {
      query = query.lt(
        'fecha_apertura',
        AppTime.toIsoLima(hasta.add(const Duration(days: 1))),
      );
    }

    final data = await query.order('fecha_cierre', ascending: false).limit(50);
    return List<Map<String, dynamic>>.from(data);
  }
}
