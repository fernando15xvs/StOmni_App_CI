import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final perfilRepositoryProvider = Provider<PerfilRepository>((ref) {
  return PerfilRepository(ref.read(supabaseProvider));
});

class PerfilRepository {
  PerfilRepository(this._client);

  final SupabaseClient _client;

  String? get emailActual => _client.auth.currentUser?.email;

  Future<Map<String, dynamic>?> obtenerPerfilActual() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final data = await _client
        .from('empleados')
        .select('nombre, rol')
        .eq('auth_id', user.id)
        .maybeSingle();

    return data == null ? null : Map<String, dynamic>.from(data);
  }
}
