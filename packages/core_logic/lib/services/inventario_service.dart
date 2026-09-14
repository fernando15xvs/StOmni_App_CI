import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

class InventarioService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  static Future<Map<String, dynamic>> registrarIngresoMercaderia({
    required String requestId,
    required int productoId,
    required DateTime fecha,
    required String tipoIngreso,
    required String documento,
    required int? proveedorId,
    required String observaciones,
    required List<Map<String, dynamic>> almacenes,
    required double ingresoCosto,
    required double ingresoPUnit,
    required double ingresoPCaja,
    required double ingresoPCComp,
  }) async {
    try {
      final response = await _supabase.rpc(
        'registrar_ingreso_mercaderia_scaled_v2',
        params: {
          'p_request_id': requestId,
          'p_producto_id': productoId,
          'p_fecha': AppTime.toIsoLima(fecha),
          'p_tipo_ingreso': tipoIngreso,
          'p_documento': documento.trim(),
          'p_proveedor_id': proveedorId,
          'p_observaciones': observaciones.trim(),
          'p_almacenes': almacenes,
          'p_ingreso_costo': ingresoCosto,
          'p_ingreso_p_unit': ingresoPUnit,
          'p_ingreso_p_caja': ingresoPCaja,
          'p_ingreso_p_c_comp': ingresoPCComp,
        },
      );
      if (response is Map<String, dynamic>) return response;
      if (response is Map) return Map<String, dynamic>.from(response);
      throw StateError(
        'registrar_ingreso_mercaderia_scaled_v2 devolvió una respuesta inválida.',
      );
    } catch (e) {
      debugPrint('Error registrando ingreso de mercadería: $e');
      rethrow;
    }
  }

  static Future<void> ajustarStock({
    required int productoId,
    required int almacenId,
    required double delta,
    String motivo = 'Ajuste Manual',
    String? tipoMovimiento,
    double? ingresoCosto,
    double? ingresoPUnit,
    double? ingresoPCaja,
    double? ingresoPCComp,
    String? salidaCliente,
    double? salidaPUnit,
    double? salidaTotal,
  }) async {
    try {
      await _supabase.rpc(
        'ajustar_stock_scaled_v2',
        params: {
          'p_producto_id': productoId,
          'p_almacen_id': almacenId,
          'p_delta_base': delta,
          'p_tipo_movimiento':
              tipoMovimiento ?? (delta > 0 ? 'ENTRADA' : 'SALIDA'),
          'p_motivo': motivo,
          'p_ingreso_costo': ingresoCosto ?? 0,
          'p_ingreso_p_unit': ingresoPUnit ?? 0,
          'p_ingreso_p_caja': ingresoPCaja ?? 0,
          'p_ingreso_p_c_comp': ingresoPCComp ?? 0,
          'p_salida_cliente': salidaCliente,
          'p_salida_p_unit': salidaPUnit ?? 0,
          'p_salida_total': salidaTotal ?? 0,
        },
      );
    } catch (e) {
      debugPrint('Error ajustando stock y Kardex: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> registrarMerma({
    required String requestId,
    required int productoId,
    required int almacenId,
    required double cantidad,
    required String motivo,
    DateTime? fecha,
    List<String> serialNumbers = const <String>[],
  }) async {
    try {
      final response = await _supabase.rpc(
        'registrar_merma_scaled_v4',
        params: {
          'p_request_id': requestId,
          'p_producto_id': productoId,
          'p_almacen_id': almacenId,
          'p_cantidad_base': cantidad,
          'p_motivo': motivo.trim(),
          'p_fecha': AppTime.toIsoLima(fecha ?? AppTime.now()),
          'p_serial_numbers': serialNumbers.isEmpty
              ? null
              : List<String>.unmodifiable(serialNumbers),
        },
      );
      if (response is Map<String, dynamic>) return response;
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      debugPrint('Error registrando merma: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> trasladarStock({
    required String requestId,
    required int productoId,
    required int origenId,
    required int destinoId,
    required double cantidad,
    String motivo = '',
    DateTime? fecha,
    List<String> serialNumbers = const <String>[],
  }) async {
    try {
      final response = await _supabase.rpc(
        'trasladar_stock_scaled_v4',
        params: {
          'p_request_id': requestId,
          'p_producto_id': productoId,
          'p_origen_id': origenId,
          'p_destino_id': destinoId,
          'p_cantidad_base': cantidad,
          'p_motivo': motivo.trim(),
          'p_fecha': AppTime.toIsoLima(fecha ?? AppTime.now()),
          'p_serial_numbers': serialNumbers.isEmpty
              ? null
              : List<String>.unmodifiable(serialNumbers),
        },
      );
      if (response is Map<String, dynamic>) return response;
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      debugPrint('Error trasladando stock: $e');
      rethrow;
    }
  }
}
