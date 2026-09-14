import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final almacenAdminRepositoryProvider = Provider<AlmacenAdminRepository>((ref) {
  return AlmacenAdminRepository(ref.read(supabaseProvider));
});

class AlmacenAdminRepository {
  AlmacenAdminRepository(this._client);

  final SupabaseClient _client;

  Future<void> _requireAdmin() async {
    if (_client.auth.currentUser == null) {
      throw const UserFacingException(
        'Tu sesión ya no está disponible. Inicia sesión nuevamente.',
      );
    }

    try {
      final raw = await _client.rpc('get_my_tenant_context_v1');
      if (raw is! Map || !AppRoles.isAdmin(raw['base_role']?.toString())) {
        throw const UserFacingException(
          'Solo un administrador activo puede configurar almacenes.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<List<Map<String, dynamic>>> listarAlmacenes() async {
    await _requireAdmin();
    final data = await _client
        .from('almacenes')
        .select()
        .order('activo', ascending: false)
        .order('nombre');
    return List<Map<String, dynamic>>.from(data);
  }

  Future<void> guardar({
    int? id,
    required String nombre,
    required String direccion,
    required String ubigeo,
    required String departamento,
    required String provincia,
    required String distrito,
    required String codLocal,
    String? referencia,
  }) async {
    await _requireAdmin();

    final values = <String, dynamic>{
      'nombre': nombre.trim(),
      'direccion': _nullIfEmpty(direccion),
      'ubigeo': _nullIfEmpty(ubigeo),
      'departamento': _nullIfEmpty(departamento)?.toUpperCase(),
      'provincia': _nullIfEmpty(provincia)?.toUpperCase(),
      'distrito': _nullIfEmpty(distrito)?.toUpperCase(),
      'cod_local': _nullIfEmpty(codLocal) ?? '0000',
      'referencia': _nullIfEmpty(referencia),
      if (id == null) 'activo': true,
    };

    if (id == null) {
      await _client.from('almacenes').insert(values);
    } else {
      await _client.from('almacenes').update(values).eq('id', id);
    }
  }

  Future<void> desactivar(int id) async {
    await _requireAdmin();
    try {
      final raw = await _client.rpc(
        'desactivar_almacen_seguro_v1',
        params: {'p_almacen_id': id},
      );
      if (raw is! Map || raw['success'] != true) {
        throw const UserFacingException(
          'No se pudo confirmar la desactivación del almacén.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> reactivar(int id) async {
    await _requireAdmin();
    try {
      final raw = await _client.rpc(
        'reactivar_almacen_seguro_v1',
        params: {'p_almacen_id': id},
      );
      if (raw is! Map || raw['success'] != true) {
        throw const UserFacingException(
          'No se pudo confirmar la reactivación del almacén.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  String? _nullIfEmpty(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
