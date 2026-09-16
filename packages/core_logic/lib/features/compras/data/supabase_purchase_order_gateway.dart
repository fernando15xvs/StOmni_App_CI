import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/app_time.dart';
import '../application/purchase_order_use_case.dart';
import '../domain/purchase_order.dart';

class SupabasePurchaseOrderGateway implements PurchaseOrderGateway {
  const SupabasePurchaseOrderGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<PurchaseOrderRecord>> list({
    PurchaseOrderStatus? status,
    int limit = 100,
  }) async {
    final raw = await client.rpc(
      'list_purchase_orders_v1',
      params: {'p_status': status?.databaseValue, 'p_limit': limit},
    );
    if (raw is! List) {
      throw const FormatException('El listado de compras es inválido.');
    }
    return raw.map(_decode).toList(growable: false);
  }

  @override
  Future<PurchaseOrderRecord> create(PurchaseOrderDraft draft) async {
    final raw = await client.rpc(
      'create_purchase_order_v1',
      params: {
        'p_request_id': draft.requestId,
        'p_supplier_id': draft.supplierId,
        'p_warehouse_id': draft.warehouseId,
        'p_ordered_at': AppTime.toIsoLima(draft.orderedAt),
        'p_expected_at': draft.expectedAt == null
            ? null
            : AppTime.toIsoLima(draft.expectedAt!),
        'p_notes': draft.notes,
        'p_lines': draft.lines
            .map(
              (line) => <String, dynamic>{
                'product_id': line.productId,
                'base_quantity': line.baseQuantity,
                'unit_cost': line.unitCost,
              },
            )
            .toList(growable: false),
      },
    );
    return _decode(raw);
  }

  @override
  Future<PurchaseOrderRecord> receive(
    ReceivePurchaseOrderCommand command,
  ) async {
    final raw = await client.rpc(
      'receive_purchase_order_v2',
      params: {
        'p_request_id': command.requestId,
        'p_purchase_order_id': command.purchaseOrderId,
        'p_received_at': AppTime.toIsoLima(command.receivedAt),
        'p_document': command.document,
        'p_notes': command.notes,
        'p_lines': command.lines
            .map(
              (line) => <String, dynamic>{
                'purchase_order_line_id': line.purchaseOrderLineId,
                'base_quantity': line.baseQuantity,
                'allocations': [
                  ...line.lots.map(
                    (lot) => <String, dynamic>{
                      'lot_code': lot.lotCode,
                      'base_quantity': lot.baseQuantity,
                      'expiry_date': lot.expiryDate == null
                          ? null
                          : AppTime.toIsoLima(lot.expiryDate!).split('T').first,
                    },
                  ),
                  ...line.serials.map(
                    (serial) => <String, dynamic>{
                      'serial_number': serial.serialNumber,
                    },
                  ),
                ],
              },
            )
            .toList(growable: false),
      },
    );
    return _decode(raw);
  }

  @override
  Future<PurchaseOrderRecord> cancel(
    int purchaseOrderId, {
    required String reason,
  }) async {
    final raw = await client.rpc(
      'cancel_purchase_order_v1',
      params: {'p_purchase_order_id': purchaseOrderId, 'p_reason': reason},
    );
    return _decode(raw);
  }

  PurchaseOrderRecord _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Registro de compra inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final id = _requiredInt(map['id'], 'id');
    final supplierId = _requiredInt(map['supplier_id'], 'supplier_id');
    final warehouseId = _requiredInt(map['warehouse_id'], 'warehouse_id');
    final requestId = map['request_id']?.toString().trim() ?? '';
    final orderedAt = DateTime.tryParse(map['ordered_at']?.toString() ?? '');
    final status = PurchaseOrderStatus.parse(map['status']?.toString() ?? '');
    final rawLines = map['lines'];
    if (requestId.isEmpty || orderedAt == null || rawLines is! List) {
      throw const FormatException('Contrato de compra incompleto.');
    }
    return PurchaseOrderRecord(
      id: id,
      requestId: requestId,
      supplierId: supplierId,
      supplierName: map['supplier_name']?.toString().trim() ?? '',
      warehouseId: warehouseId,
      warehouseName: map['warehouse_name']?.toString().trim() ?? '',
      status: status,
      orderedAt: orderedAt,
      expectedAt: map['expected_at'] == null
          ? null
          : DateTime.tryParse(map['expected_at'].toString()),
      notes: map['notes']?.toString() ?? '',
      lines: rawLines.map((rawLine) {
        if (rawLine is! Map) {
          throw const FormatException('Línea de compra inválida.');
        }
        final line = Map<String, dynamic>.from(rawLine);
        final ordered = _requiredDouble(
          line['ordered_base_quantity'],
          'ordered_base_quantity',
        );
        final received = _requiredDouble(
          line['received_base_quantity'],
          'received_base_quantity',
        );
        final cost = _requiredDouble(line['unit_cost'], 'unit_cost');
        if (ordered <= 0 || received < 0 || received > ordered || cost < 0) {
          throw const FormatException('Cantidades de compra inconsistentes.');
        }
        return PurchaseOrderLine(
          id: _requiredInt(line['id'], 'line.id'),
          productId: _requiredInt(line['product_id'], 'line.product_id'),
          productName: line['product_name']?.toString().trim() ?? '',
          orderedBaseQuantity: ordered,
          receivedBaseQuantity: received,
          unitCost: cost,
        );
      }),
    );
  }

  int _requiredInt(Object? value, String field) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) {
      throw FormatException('Campo $field inválido.');
    }
    return parsed;
  }

  double _requiredDouble(Object? value, String field) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (parsed == null || !parsed.isFinite) {
      throw FormatException('Campo $field inválido.');
    }
    return parsed;
  }
}
