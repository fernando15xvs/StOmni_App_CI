import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final procesosTributariosRepositoryProvider =
    Provider<ProcesosTributariosRepository>((ref) {
      return ProcesosTributariosRepository(ref.read(supabaseProvider));
    });

class ProcesosTributariosRepository {
  final SupabaseClient _client;

  ProcesosTributariosRepository(this._client);

  Future<Map<String, dynamic>> solicitarBaja({
    required String requestId,
    required String tipoOrigen,
    required String origenId,
    required String motivo,
  }) async {
    try {
      final result = await _client.rpc(
        'solicitar_baja_tributaria_v1',
        params: {
          'p_request_id': requestId,
          'p_tipo_origen': tipoOrigen,
          'p_origen_id': origenId,
          'p_motivo': motivo,
        },
      );
      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw StateError('La solicitud devolvió una respuesta inválida.');
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudo solicitar la baja tributaria: $e');
    }
  }

  Future<List<Map<String, dynamic>>> listarSolicitudes({
    required DateTime fechaInicio,
    required DateTime finExclusivo,
    int limite = 50,
  }) async {
    try {
      final result = await _client
          .from('solicitudes_baja_tributaria')
          .select()
          .gte('created_at', AppTime.toIsoLima(fechaInicio))
          .lt('created_at', AppTime.toIsoLima(finExclusivo))
          .order('created_at', ascending: false)
          .limit(limite);
      return List<Map<String, dynamic>>.from(result);
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudieron cargar las solicitudes de baja: $e');
    }
  }

  Future<List<Map<String, dynamic>>> listarProcesos({
    required DateTime fechaInicio,
    required DateTime finExclusivo,
    int limite = 50,
  }) async {
    try {
      final result = await _client
          .from('procesos_tributarios')
          .select()
          .gte('created_at', AppTime.toIsoLima(fechaInicio))
          .lt('created_at', AppTime.toIsoLima(finExclusivo))
          .order('created_at', ascending: false)
          .limit(limite);
      return List<Map<String, dynamic>>.from(result);
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudieron cargar los procesos tributarios: $e');
    }
  }
}
