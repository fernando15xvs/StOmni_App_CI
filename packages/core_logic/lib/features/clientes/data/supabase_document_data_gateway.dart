import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

class SupabaseDocumentDataGateway implements DocumentDataGateway {
  SupabaseDocumentDataGateway(this._client)
    : _personaLookupRepository = PersonaLookupRepository(_client);

  final SupabaseClient _client;
  final PersonaLookupRepository _personaLookupRepository;

  @override
  Future<List<Map<String, dynamic>>> cargarClientes() async {
    try {
      final data = await _client
          .from('clientes')
          .select('id, nombre, dni_ruc, direccion');
      return List<Map<String, dynamic>>.from(data);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  @override
  Future<Map<String, dynamic>?> consultarPersona({
    required String numero,
    required String tipo,
  }) async {
    try {
      return await _personaLookupRepository.consultar(
        numero: numero,
        tipo: tipo,
      );
    } on FunctionException catch (error) {
      final detalles = error.details;
      if (detalles is Map && detalles['error'] != null) {
        throw DocumentLookupException(detalles['error'].toString());
      }
      throw const DocumentLookupException(
        'Documento no encontrado o servidor ocupado.',
      );
    }
  }

  @override
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  }) async {
    final inputRuc = ruc.trim();
    final inputNombre = nombre.trim();
    final inputDir = direccion.trim();

    final docFinal = inputRuc.isNotEmpty
        ? inputRuc
        : (inputNombre.isNotEmpty || inputDir.isNotEmpty
              ? 'SD-${DateTime.now().millisecondsSinceEpoch.toString().substring(9)}'
              : '00000000');
    final nombreFinal = inputNombre.isNotEmpty
        ? inputNombre
        : (inputRuc.isNotEmpty ? 'Cliente' : 'Cliente General');
    final dirFinal = inputDir.isNotEmpty ? inputDir : '-';

    final existente = await _client
        .from('clientes')
        .select('id')
        .eq('dni_ruc', docFinal)
        .maybeSingle();

    if (existente != null) {
      final id = (existente['id'] as num).toInt();
      await _client
          .from('clientes')
          .update({'nombre': nombreFinal, 'direccion': dirFinal})
          .eq('id', id);
      return id;
    }

    try {
      final nuevo = await _client
          .from('clientes')
          .insert({
            'dni_ruc': docFinal,
            'nombre': nombreFinal,
            'direccion': dirFinal,
          })
          .select('id')
          .single();
      return (nuevo['id'] as num).toInt();
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
      final recuperado = await _client
          .from('clientes')
          .select('id')
          .eq('dni_ruc', docFinal)
          .single();
      return (recuperado['id'] as num).toInt();
    }
  }
}
