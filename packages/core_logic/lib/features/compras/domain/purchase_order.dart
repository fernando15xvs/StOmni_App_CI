import '../../trazabilidad/domain/inventory_traceability.dart';

enum PurchaseOrderStatus {
  draft,
  ordered,
  partiallyReceived,
  received,
  cancelled;

  static PurchaseOrderStatus parse(String raw) => switch (raw
      .trim()
      .toLowerCase()) {
    'draft' || 'borrador' => PurchaseOrderStatus.draft,
    'ordered' || 'ordenada' => PurchaseOrderStatus.ordered,
    'partially_received' || 'parcial' => PurchaseOrderStatus.partiallyReceived,
    'received' || 'recibida' => PurchaseOrderStatus.received,
    'cancelled' || 'anulada' => PurchaseOrderStatus.cancelled,
    _ => throw FormatException('Estado de orden de compra desconocido: $raw'),
  };

  String get databaseValue => switch (this) {
    PurchaseOrderStatus.draft => 'draft',
    PurchaseOrderStatus.ordered => 'ordered',
    PurchaseOrderStatus.partiallyReceived => 'partially_received',
    PurchaseOrderStatus.received => 'received',
    PurchaseOrderStatus.cancelled => 'cancelled',
  };
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.orderedBaseQuantity,
    required this.receivedBaseQuantity,
    required this.unitCost,
  });

  final int id;
  final int productId;
  final String productName;
  final double orderedBaseQuantity;
  final double receivedBaseQuantity;
  final double unitCost;

  double get pendingBaseQuantity =>
      (orderedBaseQuantity - receivedBaseQuantity).clamp(0, double.infinity);
  double get orderedAmount => orderedBaseQuantity * unitCost;
  double get receivedAmount => receivedBaseQuantity * unitCost;
}

class PurchaseOrderRecord {
  PurchaseOrderRecord({
    required this.id,
    required this.requestId,
    required this.supplierId,
    required this.supplierName,
    required this.warehouseId,
    required this.warehouseName,
    required this.status,
    required this.orderedAt,
    required this.expectedAt,
    required this.notes,
    required Iterable<PurchaseOrderLine> lines,
  }) : lines = List<PurchaseOrderLine>.unmodifiable(lines);

  final int id;
  final String requestId;
  final int supplierId;
  final String supplierName;
  final int warehouseId;
  final String warehouseName;
  final PurchaseOrderStatus status;
  final DateTime orderedAt;
  final DateTime? expectedAt;
  final String notes;
  final List<PurchaseOrderLine> lines;

  double get total => lines.fold(0, (sum, line) => sum + line.orderedAmount);
  bool get canReceive =>
      status == PurchaseOrderStatus.ordered ||
      status == PurchaseOrderStatus.partiallyReceived;
}

class PurchaseOrderLineDraft {
  const PurchaseOrderLineDraft({
    required this.productId,
    required this.baseQuantity,
    required this.unitCost,
  });

  final int productId;
  final double baseQuantity;
  final double unitCost;
}

class PurchaseOrderDraft {
  PurchaseOrderDraft({
    required this.requestId,
    required this.supplierId,
    required this.warehouseId,
    required this.orderedAt,
    required Iterable<PurchaseOrderLineDraft> lines,
    this.expectedAt,
    this.notes = '',
  }) : lines = List<PurchaseOrderLineDraft>.unmodifiable(lines);

  final String requestId;
  final int supplierId;
  final int warehouseId;
  final DateTime orderedAt;
  final DateTime? expectedAt;
  final String notes;
  final List<PurchaseOrderLineDraft> lines;
}

class PurchaseReceiptLine {
  PurchaseReceiptLine({
    required this.purchaseOrderLineId,
    required this.baseQuantity,
    Iterable<LotReceiptAllocation> lots = const <LotReceiptAllocation>[],
    Iterable<SerialReceiptAllocation> serials =
        const <SerialReceiptAllocation>[],
  }) : lots = List<LotReceiptAllocation>.unmodifiable(lots),
       serials = List<SerialReceiptAllocation>.unmodifiable(serials);

  final int purchaseOrderLineId;
  final double baseQuantity;
  final List<LotReceiptAllocation> lots;
  final List<SerialReceiptAllocation> serials;

  bool get hasTraceability => lots.isNotEmpty || serials.isNotEmpty;
}

class ReceivePurchaseOrderCommand {
  ReceivePurchaseOrderCommand({
    required this.requestId,
    required this.purchaseOrderId,
    required this.receivedAt,
    required Iterable<PurchaseReceiptLine> lines,
    this.document = '',
    this.notes = '',
  }) : lines = List<PurchaseReceiptLine>.unmodifiable(lines);

  final String requestId;
  final int purchaseOrderId;
  final DateTime receivedAt;
  final String document;
  final String notes;
  final List<PurchaseReceiptLine> lines;
}
