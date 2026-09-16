import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final personaLookupRepositoryProvider = Provider<PersonaLookupRepository>((
  ref,
) {
  return PersonaLookupRepository(ref.watch(supabaseProvider));
});

class PersonaLookupRepository {
  PersonaLookupRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>?> consultar({
    required String numero,
    required String tipo,
  }) async {
    try {
      final response = await _client.functions
          .invoke('get-persona', body: {'numero': numero, 'tipo': tipo})
          .timeout(const Duration(seconds: 15));

      if (response.status != 200 || response.data == null) {
        final data = response.data;
        final message = data is Map ? data['error']?.toString() : null;
        throw UserFacingException(_mensajeConsulta(message, tipo: tipo));
      }

      final data = response.data;
      if (data is! Map) {
        throw const UserFacingException(
          'La consulta devolvió una respuesta inválida. Inténtalo nuevamente.',
        );
      }

      final payload = data['data'];
      if (payload == null) return null;
      if (payload is! Map) {
        throw const UserFacingException(
          'La consulta devolvió datos incompletos. Inténtalo nuevamente.',
        );
      }

      return Map<String, dynamic>.from(payload);
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  String _mensajeConsulta(String? raw, {required String tipo}) {
    final text = raw?.trim() ?? '';
    final lower = text.toLowerCase();

    if (lower.contains('no encontr') || lower.contains('not found')) {
      return tipo == 'dni'
          ? 'No encontramos información para ese DNI.'
          : 'No encontramos información para ese RUC.';
    }
    if (lower.contains('inválid') || lower.contains('invalid')) {
      return tipo == 'dni' ? 'El DNI no es válido.' : 'El RUC no es válido.';
    }
    if (lower.contains('límite') || lower.contains('limit')) {
      return 'El servicio de consulta alcanzó su límite temporal. Inténtalo más tarde.';
    }

    return 'No pudimos consultar el documento en este momento. Inténtalo nuevamente.';
  }
}
