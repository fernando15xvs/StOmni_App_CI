enum ProductTraceabilityMode { none, lot, serial }

class ProductTraceabilityConfig {
  const ProductTraceabilityConfig({
    required this.productId,
    required this.mode,
    required this.expiryRequired,
    required this.revision,
  });

  final int productId;
  final ProductTraceabilityMode mode;
  final bool expiryRequired;
  final int revision;

  bool get lotTracked => mode == ProductTraceabilityMode.lot;
  bool get serialTracked => mode == ProductTraceabilityMode.serial;
}

class LotStockRecord {
  const LotStockRecord({
    required this.id,
    required this.productId,
    required this.productName,
    required this.warehouseId,
    required this.warehouseName,
    required this.lotCode,
    required this.baseQuantity,
    this.expiryDate,
  });

  final int id;
  final int productId;
  final String productName;
  final int warehouseId;
  final String warehouseName;
  final String lotCode;
  final double baseQuantity;
  final DateTime? expiryDate;

  bool expiresBefore(DateTime date) =>
      expiryDate != null && expiryDate!.isBefore(date);
}

class SerialStockRecord {
  const SerialStockRecord({
    required this.id,
    required this.productId,
    required this.productName,
    required this.warehouseId,
    required this.warehouseName,
    required this.serialNumber,
    required this.status,
  });

  final int id;
  final int productId;
  final String productName;
  final int warehouseId;
  final String warehouseName;
  final String serialNumber;
  final String status;

  bool get inStock => status == 'in_stock';
}

class LotReceiptAllocation {
  const LotReceiptAllocation({
    required this.lotCode,
    required this.baseQuantity,
    this.expiryDate,
  });

  final String lotCode;
  final double baseQuantity;
  final DateTime? expiryDate;
}

class SerialReceiptAllocation {
  const SerialReceiptAllocation(this.serialNumber);
  final String serialNumber;
}

class TraceableReceiptCommand {
  const TraceableReceiptCommand({
    required this.requestId,
    required this.productId,
    required this.warehouseId,
    required this.totalBaseQuantity,
    this.lots = const [],
    this.serials = const [],
  });

  final String requestId;
  final int productId;
  final int warehouseId;
  final double totalBaseQuantity;
  final List<LotReceiptAllocation> lots;
  final List<SerialReceiptAllocation> serials;
}
