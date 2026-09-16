import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/app_time.dart';
import '../application/reporting_use_case.dart';

class SupabaseReportingGateway implements ReportingGateway {
  const SupabaseReportingGateway(this.client);

  final SupabaseClient client;
  static const _pageSize = 1000;

  @override
  Future<ReportingSnapshot> loadPeriod({
    required DateTime start,
    required DateTime end,
  }) async {
    final results = await Future.wait<Object>([
      _loadFinancial(start, end),
      _loadInventory(start, end),
      _loadDiscounts(start, end),
    ]);
    return ReportingSnapshot(
      financialMovements: results[0] as List<FinancialMovementRecord>,
      inventoryMovements: results[1] as List<InventoryMovementRecord>,
      totalDiscounts: results[2] as double,
    );
  }

  Future<List<FinancialMovementRecord>> _loadFinancial(
    DateTime start,
    DateTime end,
  ) async {
    final from = AppTime.toIsoLima(start);
    final to = AppTime.toIsoLima(end.add(const Duration(seconds: 1)));
    final result = <FinancialMovementRecord>[];
    var offset = 0;
    while (true) {
      final raw = await client
          .from('reportes_movimientos_financieros')
          .select()
          .gte('fecha', from)
          .lt('fecha', to)
          .order('fecha', ascending: false)
          .order('origen', ascending: true)
          .order('origen_id', ascending: false)
          .range(offset, offset + _pageSize - 1);
      final rows = List<Map<String, dynamic>>.from(raw);
      result.addAll(rows.map(_financial));
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }
    return result;
  }

  Future<List<InventoryMovementRecord>> _loadInventory(
    DateTime start,
    DateTime end,
  ) async {
    final from = AppTime.toIsoLima(start);
    final to = AppTime.toIsoLima(end.add(const Duration(seconds: 1)));
    final result = <InventoryMovementRecord>[];
    var offset = 0;
    while (true) {
      final raw = await client
          .from('inventario_movimientos')
          .select('*, productos(codigo, tipo_venta, cantidad_por_caja)')
          .gte('fecha', from)
          .lt('fecha', to)
          .order('fecha', ascending: false)
          .order('id', ascending: false)
          .range(offset, offset + _pageSize - 1);
      final rows = List<Map<String, dynamic>>.from(raw);
      result.addAll(rows.map(_inventory));
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }
    return result;
  }

  Future<double> _loadDiscounts(DateTime start, DateTime end) async {
    final from = AppTime.toIsoLima(start);
    final to = AppTime.toIsoLima(end.add(const Duration(seconds: 1)));
    var offset = 0;
    var total = 0.0;
    while (true) {
      final raw = await client
          .from('ventas')
          .select('id, descuento_global_monto')
          .gte('fecha', from)
          .lt('fecha', to)
          .neq('estado', 'anulado')
          .order('id')
          .range(offset, offset + _pageSize - 1);
      final rows = List<Map<String, dynamic>>.from(raw);
      for (final row in rows) {
        total += (row['descuento_global_monto'] as num?)?.toDouble() ?? 0;
      }
      if (rows.length < _pageSize) break;
      offset += _pageSize;
    }
    return total;
  }

  FinancialMovementRecord _financial(Map<String, dynamic> row) {
    final type = row['tipo']?.toString().trim().toLowerCase();
    final date = DateTime.tryParse(row['fecha']?.toString() ?? '');
    final amount = (row['monto'] as num?)?.toDouble();
    if ((type != 'ingreso' && type != 'egreso') ||
        date == null ||
        amount == null) {
      throw const FormatException('Movimiento financiero inválido.');
    }
    return FinancialMovementRecord(
      type: type == 'ingreso'
          ? FinancialMovementType.income
          : FinancialMovementType.expense,
      amount: amount.abs(),
      description: row['descripcion']?.toString().trim() ?? 'Movimiento',
      date: date,
      saleId: _int(row['venta_id']),
      expenseId: _int(row['gasto_id']),
      employeePaymentId: _int(row['pago_empleado_id']),
      paymentMethod: _text(row['metodo_pago']),
    );
  }

  InventoryMovementRecord _inventory(Map<String, dynamic> row) {
    final date = DateTime.tryParse(row['fecha']?.toString() ?? '');
    final productId = _int(row['producto_id']);
    if (date == null || productId == null) {
      throw const FormatException('Movimiento de inventario inválido.');
    }
    final product = row['productos'] is Map
        ? Map<String, dynamic>.from(row['productos'] as Map)
        : const <String, dynamic>{};
    return InventoryMovementRecord(
      productId: productId,
      productName: row['producto_nombre']?.toString().trim().isNotEmpty == true
          ? row['producto_nombre'].toString().trim()
          : product['codigo']?.toString().trim() ?? 'Producto',
      warehouseName: row['almacen_nombre']?.toString().trim() ?? 'Sin almacén',
      movementType: row['tipo']?.toString().trim().isNotEmpty == true
          ? row['tipo'].toString().trim()
          : row['tipo_movimiento']?.toString().trim() ?? 'Movimiento',
      date: date,
      quantity: ((row['cantidad'] as num?)?.toDouble() ?? 0).abs(),
      entryQuantity: ((row['ingreso_cant'] as num?)?.toDouble() ?? 0).abs(),
      exitQuantity: ((row['salida_cant'] as num?)?.toDouble() ?? 0).abs(),
      observations: _text(row['observaciones']),
      unitLabel: _text(row['unidad_label']),
      saleUnitType: _text(product['tipo_venta']),
      saleUnitTypeSnapshot: _text(row['tipo_venta_snapshot']),
      baseUnitSnapshot: _text(row['unidad_base_snapshot']),
      unitsPerPackage: _int(product['cantidad_por_caja']),
      unitsPerPackageSnapshot: _int(row['pcs']),
    );
  }

  int? _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  String? _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}
