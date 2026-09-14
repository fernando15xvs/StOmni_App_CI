import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final greUbigeosRepositoryProvider = Provider<GreUbigeosRepository>((ref) {
  return GreUbigeosRepository(ref.watch(supabaseProvider));
});

class GreUbigeosRepository {
  GreUbigeosRepository(this._client);

  final SupabaseClient _client;

  Future<List<Map<String, dynamic>>> buscar(String raw) async {
    final safe = raw.trim().replaceAll(
      RegExp(r'[^0-9A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]'),
      ' ',
    );

    dynamic query = _client
        .from('gre_ubigeos')
        .select('codigo,departamento,provincia,distrito')
        .eq('activo', true);

    if (safe.isNotEmpty) {
      query = query.or(
        'codigo.ilike.%$safe%,'
        'departamento.ilike.%$safe%,'
        'provincia.ilike.%$safe%,'
        'distrito.ilike.%$safe%',
      );
    }

    final rows = await query
        .order('departamento')
        .order('provincia')
        .order('distrito')
        .limit(60);

    return List<Map<String, dynamic>>.from(rows as List);
  }
}
