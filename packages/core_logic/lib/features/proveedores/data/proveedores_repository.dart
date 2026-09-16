import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final proveedoresRepositoryProvider = Provider<ProveedoresRepository>((ref) {
  return ProveedoresRepository(ref.read(supabaseProvider));
});

class ProveedoresRepository {
  final SupabaseClient _client;

  ProveedoresRepository(this._client);

  /// Listado administrativo: conserva activos e inactivos para no perder
  /// visibilidad del historial ni impedir una futura reactivación.
  Future<List<dynamic>> obtenerProveedores(String busqueda) async {
    return _obtenerProveedores(busqueda, soloActivos: false);
  }

  /// Listado operativo para compras, ingresos y nuevos gastos.
  ///
  /// Un proveedor desactivado conserva todo su historial, pero no debe poder
  /// seleccionarse para crear una operación nueva.
  Future<List<dynamic>> obtenerProveedoresActivos([
    String busqueda = '',
  ]) async {
    return _obtenerProveedores(busqueda, soloActivos: true);
  }

  Future<List<dynamic>> _obtenerProveedores(
    String busqueda, {
    required bool soloActivos,
  }) async {
    var query = _client.from('proveedores').select();

    if (soloActivos) {
      query = query.eq('estado', 'activo').eq('activo', true);
    }

    final texto = busqueda.trim();
    if (texto.isNotEmpty) {
      query = query.or('nombre.ilike.%$texto%,ruc.ilike.%$texto%');
    }

    return query.order('nombre');
  }

  Future<bool> existeDocumento(String documento, {int? excluirId}) async {
    final value = documento.trim();
    if (value.isEmpty) return false;

    var query = _client.from('proveedores').select('id').eq('ruc', value);
    if (excluirId != null) {
      query = query.neq('id', excluirId);
    }

    final row = await query.limit(1).maybeSingle();
    return row != null;
  }

  Future<void> guardarProveedor(Map<String, dynamic> datos, {int? id}) async {
    if (id == null) {
      await _client.from('proveedores').insert(datos);
    } else {
      await _client.from('proveedores').update(datos).eq('id', id);
    }
  }

  Future<void> desactivarProveedor(int id) async {
    await _client
        .from('proveedores')
        .update({'estado': 'inactivo', 'activo': false})
        .eq('id', id);
  }
}
