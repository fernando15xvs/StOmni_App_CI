import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final clientesRepositoryProvider = Provider<ClientesRepository>((ref) {
  return ClientesRepository(
    ref.read(supabaseProvider),
    ref.read(personaLookupRepositoryProvider),
  );
});

class ClientesRepository {
  final SupabaseClient _client;
  final PersonaLookupRepository _personaLookupRepository;

  ClientesRepository(this._client, this._personaLookupRepository);

  Future<List<Map<String, dynamic>>> obtenerClientes({
    int limit = 20,
    int offset = 0,
    String? query,
  }) async {
    var request = _client.from('clientes').select();

    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim();
      request = request.or('nombre.ilike.%$q%,dni_ruc.ilike.%$q%');
    }

    final response = await request.order('nombre').range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<void> guardarCliente(Map<String, dynamic> datos, {int? id}) async {
    if (id == null) {
      await _client.from('clientes').insert(datos);
    } else {
      await _client.from('clientes').update(datos).eq('id', id);
    }
  }

  Future<void> eliminarCliente(int id) async {
    await _client.from('clientes').delete().eq('id', id);
  }

  Future<bool> existeDocumento(String dniRuc) async {
    final existe = await _client
        .from('clientes')
        .select('id')
        .eq('dni_ruc', dniRuc)
        .maybeSingle();
    return existe != null;
  }

  Future<Map<String, dynamic>?> consultarSunatReniec(
    String numero,
    String tipo,
  ) {
    return _personaLookupRepository.consultar(numero: numero, tipo: tipo);
  }
}
