import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final gastosRepositoryProvider = Provider<GastosRepository>((ref) {
  return GastosRepository(ref.read(supabaseProvider));
});

class GastosRepository {
  final SupabaseClient _client;

  GastosRepository(this._client);

  /// Obtiene un gasto específico con sus pagos y proveedor.
  Future<Map<String, dynamic>> obtenerGastoCompleto(int gastoId) async {
    try {
      final results = await Future.wait<dynamic>([
        _client
            .from('gastos')
            .select('*, proveedores(*)')
            .eq('id', gastoId)
            .single(),
        _client
            .from('pagos_gasto')
            .select()
            .eq('gasto_id', gastoId)
            .order('fecha', ascending: false),
      ]);

      return {
        'gasto': Map<String, dynamic>.from(results[0] as Map),
        'pagos': List<Map<String, dynamic>>.from(results[1] as List),
      };
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  /// Elimina un pago y recalcula saldo/estado dentro de una única transacción
  /// PostgreSQL. `monto` y `saldoActual` se conservan temporalmente en la firma
  /// para compatibilidad con callers de UI, pero el servidor no confía en ellos.
  Future<void> eliminarPago(
    int pagoId,
    int gastoId,
    double monto,
    double saldoActual,
  ) async {
    try {
      final raw = await _client.rpc(
        'eliminar_pago_gasto_v1',
        params: {'p_pago_id': pagoId, 'p_gasto_id': gastoId},
      );

      if (raw is! Map || raw['success'] != true) {
        throw const UserFacingException(
          'El servidor no confirmó la eliminación del pago.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  /// Elimina gasto + pagos asociados de forma atómica mediante RPC. La FK de
  /// pagos_gasto usa ON DELETE CASCADE, por lo que no hay dos DELETE separados.
  Future<void> eliminarGasto(int gastoId) async {
    try {
      final raw = await _client.rpc(
        'eliminar_gasto_v1',
        params: {'p_gasto_id': gastoId},
      );

      if (raw is! Map || raw['success'] != true) {
        throw const UserFacingException(
          'El servidor no confirmó la eliminación del gasto.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  /// Crea un gasto de forma atómica a través de RPC con pagos mixtos.
  Future<void> registrarGasto({
    required int proveedorId,
    required String categoria,
    required double montoTotal,
    required String descripcion,
    required String fechaIso,
    required List<Map<String, dynamic>> pagos,
  }) async {
    try {
      await _client.rpc(
        'registrar_gasto_mixto',
        params: {
          'p_proveedor_id': proveedorId,
          'p_categoria': categoria,
          'p_monto_total': montoTotal,
          'p_descripcion': descripcion,
          'p_fecha': fechaIso,
          'p_pagos_json': pagos,
        },
      );
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  /// Solo proveedores habilitados pueden seleccionarse en un gasto nuevo.
  /// Los inactivos siguen visibles en consultas históricas del gasto ya creado.
  Future<List<dynamic>> obtenerProveedores() async {
    try {
      return await _client
          .from('proveedores')
          .select()
          .eq('estado', 'activo')
          .eq('activo', true)
          .order('nombre');
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}
