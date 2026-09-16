import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final ventaContextRepositoryProvider = Provider<VentaContextRepository>((ref) {
  return VentaContextRepository(ref.read(supabaseProvider));
});

/// Acceso a datos auxiliares necesarios para procesar una venta.
///
/// Mantiene fuera de la UI y del use case cualquier uso directo de
/// `Supabase.instance` para cliente, empleado actual y Caja Chica.
class VentaContextRepository {
  VentaContextRepository(this._client);

  final SupabaseClient _client;

  /// Identidad local de la sesión autenticada. No realiza llamadas de red y
  /// permite vincular una venta offline con la sesión que realmente la creó.
  String? get currentAuthUserId => _client.auth.currentUser?.id;

  Future<int?> resolverVendedorActivoId(int? vendedorId) async {
    if (vendedorId != null) return vendedorId;

    try {
      final currentUser = _client.auth.currentUser;
      if (currentUser == null) return null;

      final empleado = await _client
          .from('empleados')
          .select('id')
          .eq('auth_id', currentUser.id)
          .eq('activo', true)
          .maybeSingle();

      return (empleado?['id'] as num?)?.toInt();
    } catch (_) {
      // Compatibilidad con el flujo histórico: la venta puede continuar sin
      // snapshot de vendedor si esta consulta auxiliar falla temporalmente.
      return null;
    }
  }

  Future<bool> cajaChicaAbierta() async {
    final response = await _client.rpc('get_estado_caja_chica');
    if (response is! Map) {
      throw StateError(
        'La verificación de Caja Chica devolvió datos inválidos.',
      );
    }
    return response['estado']?.toString().toUpperCase() == 'ABIERTA';
  }

  /// Busca por documento; si existe actualiza nombre/dirección y si no existe
  /// crea el cliente. Conserva la recuperación frente a carrera por unique key.
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
