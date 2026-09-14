import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../providers/supabase_provider.dart';
import '../domain/dashboard_summary.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(ref.watch(supabaseProvider));
});

class DashboardRepository {
  DashboardRepository(this._client);

  final SupabaseClient _client;

  Future<String> obtenerNombreUsuarioActual() async {
    final user = _client.auth.currentUser;
    if (user == null) return 'Usuario';

    final metaName = user.userMetadata?['nombre'] ?? user.userMetadata?['name'];
    if (metaName != null && metaName.toString().trim().isNotEmpty) {
      return metaName.toString();
    }

    try {
      final data = await _client
          .from('empleados')
          .select('nombre')
          .eq('auth_id', user.id)
          .maybeSingle();
      if (data != null && data['nombre'] != null) {
        return data['nombre'].toString();
      }
    } catch (_) {}

    final email = user.email;
    if (email == null || email.trim().isEmpty) return 'Usuario';
    return email.split('@').first;
  }

  Future<Map<String, dynamic>> obtenerResumen({
    required String inicioIso,
    required String finIso,
  }) async {
    final response = await _client.rpc(
      'get_dashboard_summary',
      params: {'inicio': inicioIso, 'fin': finIso},
    );
    if (response is! Map) {
      throw StateError('El resumen del Dashboard devolvió datos inválidos.');
    }
    return Map<String, dynamic>.from(response);
  }

  Future<DashboardSummary> obtenerResumenTipado({
    required String inicioIso,
    required String finIso,
  }) async {
    final raw = await obtenerResumen(inicioIso: inicioIso, finIso: finIso);
    return DashboardSummary.fromMap(raw);
  }

  Future<List<Map<String, dynamic>>> obtenerTendenciaMovimientos({
    required String tipo,
    required String inicioIso,
    required String finIso,
  }) async {
    final response = await _client.rpc(
      'obtener_tendencia_movimientos',
      params: {
        'p_tipo': tipo,
        'p_inicio': inicioIso,
        'p_fin': finIso,
      },
    );

    final rows = response as List<dynamic>;
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }
}
