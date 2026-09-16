import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../utils/kardex_observation_utils.dart';

class KardexRepository {
  final SupabaseClient _client;

  KardexRepository(this._client);

  Future<List<Map<String, dynamic>>> enriquecerVentasCredito(
    List<Map<String, dynamic>> movimientos,
  ) async {
    final requestIds = movimientos
        .where((item) {
          final observacion = item['observaciones']?.toString() ?? '';
          return observacion.startsWith('Venta #') &&
              item['request_id'] != null;
        })
        .map((item) => item['request_id'].toString())
        .toSet()
        .toList();

    if (requestIds.isEmpty) return movimientos;

    try {
      final rawVentas = await _client
          .from('ventas')
          .select('request_id, estado, saldo')
          .inFilter('request_id', requestIds);

      final creditos = <String>{};
      for (final raw in rawVentas as List) {
        final venta = Map<String, dynamic>.from(raw as Map);
        if (KardexObservationUtils.esVentaCredito(venta)) {
          final requestId = venta['request_id']?.toString();
          if (requestId != null && requestId.isNotEmpty) {
            creditos.add(requestId);
          }
        }
      }

      if (creditos.isEmpty) return movimientos;

      return movimientos.map((item) {
        final requestId = item['request_id']?.toString();
        if (requestId == null || !creditos.contains(requestId)) return item;

        final copia = Map<String, dynamic>.from(item);
        copia['observaciones'] = KardexObservationUtils.etiquetarCredito(
          item['observaciones']?.toString() ?? '',
          esCredito: true,
        );
        return copia;
      }).toList();
    } catch (e) {
      debugPrint('No se pudo enriquecer el tipo de venta del Kardex: $e');
      return movimientos;
    }
  }

  Future<List<Map<String, dynamic>>> consultarPagina({
    required String fechaInicio,
    required String fechaFin,
    required int limit,
    required int offset,
    int? productoId,
  }) async {
    dynamic query = _client
        .from('inventario_movimientos')
        .select('*, productos(codigo, tipo_venta, cantidad_por_caja)')
        .gte('fecha', fechaInicio)
        .lt('fecha', fechaFin);

    if (productoId != null) {
      query = query.eq('producto_id', productoId);
    }

    final raw = await query
        .order('fecha', ascending: false)
        .order('id', ascending: false)
        .range(offset, offset + limit - 1);

    final movimientos = List<Map<String, dynamic>>.from(raw as List);
    return enriquecerVentasCredito(movimientos);
  }

  Future<List<Map<String, dynamic>>> consultarNuevosMovimientos({
    required int maxId,
    required String fechaInicio,
    required String fechaFin,
    int? productoId,
  }) async {
    dynamic query = _client
        .from('inventario_movimientos')
        .select('*, productos(codigo, tipo_venta, cantidad_por_caja)')
        .gt('id', maxId)
        .gte('fecha', fechaInicio)
        .lt('fecha', fechaFin);

    if (productoId != null) {
      query = query.eq('producto_id', productoId);
    }

    final raw = await query
        .order('fecha', ascending: false)
        .order('id', ascending: false);

    final nuevosRaw = List<Map<String, dynamic>>.from(raw as List);
    if (nuevosRaw.isEmpty) return [];

    return enriquecerVentasCredito(nuevosRaw);
  }
}

final kardexRepositoryProvider = Provider<KardexRepository>((ref) {
  return KardexRepository(ref.read(supabaseProvider));
});
