import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final notasCreditoRepositoryProvider = Provider<NotasCreditoRepository>((ref) {
  return NotasCreditoRepository(ref.read(supabaseProvider));
});

class NotasCreditoRepository {
  final SupabaseClient _client;

  NotasCreditoRepository(this._client);

  Future<Map<String, dynamic>> obtenerDisponibilidad(
    String comprobanteId,
  ) async {
    try {
      Object? result;
      try {
        result = await _client.rpc(
          'obtener_disponibilidad_nota_credito_v2',
          params: {'p_comprobante_id': comprobanteId},
        );
      } on PostgrestException catch (error) {
        if (error.code != 'PGRST202' ||
            !error.message.contains('obtener_disponibilidad_nota_credito_v2')) {
          rethrow;
        }
        result = await _client.rpc(
          'obtener_disponibilidad_nota_credito',
          params: {'p_comprobante_id': comprobanteId},
        );
      }

      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw StateError('La disponibilidad devolvió una respuesta inválida.');
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudo cargar la disponibilidad: $e');
    }
  }

  Future<Map<String, dynamic>> crearNotaCredito({
    required String requestId,
    required String comprobanteId,
    required String motivoCodigo,
    String? motivoDescripcion,
    List<Map<String, dynamic>> detalles = const [],
    double? montoDescuento,
    bool reponerStock = true,
    DateTime? fecha,
  }) async {
    final params = {
      'p_request_id': requestId,
      'p_comprobante_id': comprobanteId,
      'p_motivo_codigo': motivoCodigo,
      'p_motivo_descripcion': motivoDescripcion,
      'p_detalles': detalles,
      'p_monto_descuento': montoDescuento,
      'p_reponer_stock': reponerStock,
      'p_fecha': AppTime.toIsoLima(fecha ?? AppTime.now()),
    };

    try {
      Object? result;
      try {
        result = await _client.rpc(
          'crear_nota_credito_with_units_v3',
          params: params,
        );
      } on PostgrestException catch (error) {
        if (error.code != 'PGRST202' ||
            !error.message.contains('crear_nota_credito_with_units_v3')) {
          rethrow;
        }
        // Un backend legacy sólo soporta cantidades visuales enteras. No se
        // degrada silenciosamente una cantidad decimal porque cambiaría la NC.
        for (final detail in detalles) {
          final raw = detail['cantidad'];
          if (raw is num && raw.toDouble() != raw.toDouble().roundToDouble()) {
            throw StateError(
              'Instala la migración de cantidades fraccionarias antes de emitir esta nota de crédito.',
            );
          }
        }
        result = await _client.rpc('crear_nota_credito_v1', params: params);
      }

      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw StateError('La creación devolvió una respuesta inválida.');
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudo crear la nota de crédito: $e');
    }
  }

  Future<List<Map<String, dynamic>>> listarPorVenta(int ventaId) async {
    try {
      final result = await _client
          .from('notas_credito')
          .select()
          .eq('venta_id', ventaId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(result);
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('No se pudieron cargar las notas de crédito: $e');
    }
  }
}
