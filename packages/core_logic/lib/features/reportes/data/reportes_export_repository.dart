import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/reportes_excel_snapshot.dart';
export '../domain/reportes_excel_snapshot.dart';

import '../../../providers/supabase_provider.dart';
import '../../../utils/app_time.dart';

final reportesExportRepositoryProvider = Provider<ReportesExportRepository>((ref) {
  return ReportesExportRepository(ref.read(supabaseProvider));
});


class ReportesExportRepository {
  ReportesExportRepository(this._client);

  final SupabaseClient _client;
  static const int _pageSize = 1000;

  Future<List<Map<String, dynamic>>> cargarMovimientosInventario({
    required DateTime fechaInicio,
    required DateTime fechaFin,
  }) async {
    final start = AppTime.toIsoLima(fechaInicio);
    final end = AppTime.toIsoLima(fechaFin.add(const Duration(seconds: 1)));

    return _paginar(
      (desde, hasta) => _client
          .from('inventario_movimientos')
          .select('*, productos(codigo, tipo_venta, cantidad_por_caja)')
          .gte('fecha', start)
          .lt('fecha', end)
          .order('fecha', ascending: false)
          .order('id', ascending: false)
          .range(desde, hasta),
    );
  }

  Future<ReportesExcelSnapshot> cargarExcel({
    required DateTime fechaInicio,
    required DateTime fechaFin,
    required bool incluirVentas,
    required bool incluirAbonos,
    required bool incluirGastos,
    required bool incluirPersonal,
  }) async {
    final start = AppTime.toIsoLima(fechaInicio);
    final end = AppTime.toIsoLima(fechaFin.add(const Duration(seconds: 1)));

    var almacenes = <int, String>{};
    var ventas = <Map<String, dynamic>>[];
    var detallesVentas = <Map<String, dynamic>>[];
    var pagosCredito = <Map<String, dynamic>>[];
    var detallesAbonos = <Map<String, dynamic>>[];
    var pagosGasto = <Map<String, dynamic>>[];
    var pagosPersonal = <Map<String, dynamic>>[];

    if (incluirVentas) {
      final almacenesData = await _client.from('almacenes').select('id, nombre');
      almacenes = <int, String>{
        for (final item in almacenesData)
          (item['id'] as num).toInt(): item['nombre'].toString(),
      };

      ventas = await _paginar(
        (desde, hasta) => _client
            .from('ventas')
            .select('*, clientes(*)')
            .gte('fecha', start)
            .lt('fecha', end)
            .neq('estado', 'anulado')
            .order('fecha', ascending: false)
            .order('id', ascending: false)
            .range(desde, hasta),
      );
      detallesVentas = await _cargarDetalles(
        ventas
            .map((v) => (v['id'] as num?)?.toInt())
            .whereType<int>()
            .toList(),
      );
    }

    if (incluirAbonos) {
      final pagos = await _paginar(
        (desde, hasta) => _client
            .from('pagos_venta')
            .select(
              '*, ventas!inner(id, fecha, saldo, fue_credito, clientes(*))',
            )
            .gte('fecha', start)
            .lt('fecha', end)
            .order('fecha', ascending: false)
            .order('id', ascending: false)
            .range(desde, hasta),
      );
      pagosCredito = pagos.where((p) {
        final venta = p['ventas'] as Map?;
        return venta?['fue_credito'] == true;
      }).toList();
      detallesAbonos = await _cargarDetalles(
        pagosCredito
            .map((p) => (p['venta_id'] as num?)?.toInt())
            .whereType<int>()
            .toList(),
      );
    }

    if (incluirGastos) {
      pagosGasto = await _paginar(
        (desde, hasta) => _client
            .from('pagos_gasto')
            .select('*, gastos!inner(*, proveedores(*))')
            .gte('fecha', start)
            .lt('fecha', end)
            .order('fecha', ascending: false)
            .order('id', ascending: false)
            .range(desde, hasta),
      );
    }

    if (incluirPersonal) {
      pagosPersonal = await _paginar(
        (desde, hasta) => _client
            .from('pagos_empleados')
            .select('*, empleados(*)')
            .gte('fecha', start)
            .lt('fecha', end)
            .order('fecha', ascending: false)
            .order('id', ascending: false)
            .range(desde, hasta),
      );
    }

    return ReportesExcelSnapshot(
      almacenes: almacenes,
      ventas: ventas,
      detallesVentas: detallesVentas,
      pagosCredito: pagosCredito,
      detallesAbonos: detallesAbonos,
      pagosGasto: pagosGasto,
      pagosPersonal: pagosPersonal,
    );
  }

  Future<List<Map<String, dynamic>>> _cargarDetalles(List<int> ventaIds) async {
    if (ventaIds.isEmpty) return const [];

    final resultado = <Map<String, dynamic>>[];
    final ids = ventaIds.toSet().toList();
    for (var i = 0; i < ids.length; i += 300) {
      final end = i + 300 > ids.length ? ids.length : i + 300;
      final chunk = ids.sublist(i, end);
      final rows = await _client
          .from('detalle_ventas')
          .select(
            'venta_id, cantidad, piezas_reales, precio_unitario, '
            'precio_unitario_comercial, subtotal, subtotal_final, almacen_id, '
            'tipo_unidad, tipo_venta_snapshot, pcs_snapshot, '
            'unidad_base_snapshot, productos(codigo, nombre)',
          )
          .inFilter('venta_id', chunk);
      resultado.addAll(List<Map<String, dynamic>>.from(rows));
    }
    return resultado;
  }

  Future<List<Map<String, dynamic>>> _paginar(
    Future<dynamic> Function(int desde, int hasta) cargar,
  ) async {
    final resultado = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final raw = await cargar(offset, offset + _pageSize - 1);
      final rows = List<Map<String, dynamic>>.from(raw as List);
      resultado.addAll(rows);
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }
    return resultado;
  }
}
