import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/app_time.dart';
import '../application/inventory_traceability_use_case.dart';
import '../domain/inventory_traceability.dart';

class SupabaseInventoryTraceabilityGateway
    implements InventoryTraceabilityGateway {
  const SupabaseInventoryTraceabilityGateway(this._client);
  final SupabaseClient _client;

  @override
  Future<ProductTraceabilityConfig> loadConfig(int productId) async {
    final raw = await _client.rpc(
      'get_product_traceability_config_v1',
      params: {'p_product_id': productId},
    );
    return _decodeConfig(raw);
  }

  @override
  Future<ProductTraceabilityConfig> saveConfig({
    required int productId,
    required int expectedRevision,
    required ProductTraceabilityMode mode,
    required bool expiryRequired,
  }) async {
    final raw = await _client.rpc(
      'save_product_traceability_config_v1',
      params: {
        'p_product_id': productId,
        'p_expected_revision': expectedRevision,
        'p_mode': switch (mode) {
          ProductTraceabilityMode.none => 'none',
          ProductTraceabilityMode.lot => 'lot',
          ProductTraceabilityMode.serial => 'serial',
        },
        'p_expiry_required': expiryRequired,
      },
    );
    return _decodeConfig(raw);
  }

  @override
  Future<List<LotStockRecord>> listLots({
    int? productId,
    int? warehouseId,
  }) async {
    final raw = await _client.rpc(
      'list_inventory_lots_v1',
      params: {'p_product_id': productId, 'p_warehouse_id': warehouseId},
    );
    if (raw is! List) {
      throw const FormatException('Listado de lotes inválido.');
    }
    return raw
        .map((item) {
          final row = _map(item, 'lote');
          return LotStockRecord(
            id: _int(row['id'], 'id'),
            productId: _int(row['product_id'], 'product_id'),
            productName: row['product_name']?.toString() ?? '',
            warehouseId: _int(row['warehouse_id'], 'warehouse_id'),
            warehouseName: row['warehouse_name']?.toString() ?? '',
            lotCode: row['lot_code']?.toString() ?? '',
            baseQuantity: _double(row['base_quantity'], 'base_quantity'),
            expiryDate: _date(row['expiry_date']),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<SerialStockRecord>> listSerials({
    int? productId,
    int? warehouseId,
  }) async {
    final raw = await _client.rpc(
      'list_inventory_serials_v1',
      params: {'p_product_id': productId, 'p_warehouse_id': warehouseId},
    );
    if (raw is! List) {
      throw const FormatException('Listado de series inválido.');
    }
    return raw
        .map((item) {
          final row = _map(item, 'serie');
          return SerialStockRecord(
            id: _int(row['id'], 'id'),
            productId: _int(row['product_id'], 'product_id'),
            productName: row['product_name']?.toString() ?? '',
            warehouseId: _int(row['warehouse_id'], 'warehouse_id'),
            warehouseName: row['warehouse_name']?.toString() ?? '',
            serialNumber: row['serial_number']?.toString() ?? '',
            status: row['status']?.toString() ?? '',
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> registerReceipt(TraceableReceiptCommand command) async {
    final config = await loadConfig(command.productId);
    final allocations = switch (config.mode) {
      ProductTraceabilityMode.lot =>
        command.lots
            .map(
              (lot) => <String, dynamic>{
                'lot_code': lot.lotCode.trim(),
                'base_quantity': lot.baseQuantity,
                'expiry_date': lot.expiryDate == null
                    ? null
                    : '${lot.expiryDate!.year.toString().padLeft(4, '0')}-'
                          '${lot.expiryDate!.month.toString().padLeft(2, '0')}-'
                          '${lot.expiryDate!.day.toString().padLeft(2, '0')}',
              },
            )
            .toList(growable: false),
      ProductTraceabilityMode.serial =>
        command.serials
            .map(
              (serial) => <String, dynamic>{
                'serial_number': serial.serialNumber.trim(),
              },
            )
            .toList(growable: false),
      ProductTraceabilityMode.none => const <Map<String, dynamic>>[],
    };
    await _client.rpc(
      'register_traceable_merchandise_receipt_v1',
      params: {
        'p_request_id': command.requestId,
        'p_product_id': command.productId,
        'p_warehouse_id': command.warehouseId,
        'p_total_base_quantity': command.totalBaseQuantity,
        'p_received_at': AppTime.toIsoLima(AppTime.now()),
        'p_entry_type': 'Ingreso trazable',
        'p_document': '',
        'p_supplier_id': null,
        'p_observations': '',
        'p_unit_cost': 0,
        'p_unit_price': 0,
        'p_box_price': 0,
        'p_comparative_box_price': 0,
        'p_allocations': allocations,
      },
    );
  }

  ProductTraceabilityConfig _decodeConfig(Object? raw) {
    final row = _map(raw, 'configuración de trazabilidad');
    final rawMode = row['mode']?.toString();
    final mode = switch (rawMode) {
      'none' => ProductTraceabilityMode.none,
      'lot' => ProductTraceabilityMode.lot,
      'serial' => ProductTraceabilityMode.serial,
      _ => throw const FormatException('Modo de trazabilidad inválido.'),
    };
    final revisionRaw = row['revision'];
    final revision = revisionRaw is num
        ? revisionRaw.toInt()
        : int.tryParse(revisionRaw?.toString() ?? '');
    if (revision == null || revision < 0 || row['expiry_required'] is! bool) {
      throw const FormatException('Configuración de trazabilidad inválida.');
    }
    return ProductTraceabilityConfig(
      productId: _int(row['product_id'], 'product_id'),
      mode: mode,
      expiryRequired: row['expiry_required'] == true,
      revision: revision,
    );
  }

  Map<String, dynamic> _map(Object? raw, String source) {
    if (raw is! Map) throw FormatException('Respuesta de $source inválida.');
    return Map<String, dynamic>.from(raw);
  }

  int _int(Object? value, String field) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed <= 0)
      throw FormatException('$field inválido.');
    return parsed;
  }

  double _double(Object? value, String field) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      throw FormatException('$field inválido.');
    }
    return parsed;
  }

  DateTime? _date(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null)
      throw const FormatException('Fecha de vencimiento inválida.');
    return parsed;
  }
}
