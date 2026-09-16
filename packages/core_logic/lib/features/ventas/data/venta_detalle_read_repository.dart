import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final ventaDetalleReadRepositoryProvider = Provider<VentaDetalleReadRepository>(
  (ref) => VentaDetalleReadRepository(ref.read(supabaseProvider)),
);

/// Read-model del detalle de una venta.
///
/// Mantiene fuera de la página las lecturas auxiliares que no forman parte del
/// agregado principal devuelto por [VentasRepository]: nombres históricos de
/// almacenes y el comprobante electrónico reservado para la venta.
class VentaDetalleReadRepository {
  VentaDetalleReadRepository(this._client);

  final SupabaseClient _client;

  Future<Map<int, String>> obtenerNombresAlmacenesHistoricos() async {
    final rows = await _client
        .from('almacenes')
        .select('id, nombre')
        .order('id');
    return <int, String>{
      for (final row in rows)
        if (row['id'] is num)
          (row['id'] as num).toInt(): row['nombre']?.toString() ?? 'Almacén',
    };
  }

  Future<Map<String, dynamic>?> obtenerComprobantePorVenta(int ventaId) async {
    final row = await _client
        .from('comprobantes_electronicos')
        .select()
        .eq('venta_id', ventaId)
        .maybeSingle();

    if (row == null) return null;
    return Map<String, dynamic>.from(row);
  }
}
