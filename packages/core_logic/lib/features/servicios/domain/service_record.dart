class ServiceRecord {
  const ServiceRecord({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.unitPrice,
    required this.purchasePrice,
    required this.active,
  });

  final int id;
  final String code;
  final String name;
  final String description;
  final double unitPrice;
  final double purchasePrice;
  final bool active;
}

class ServiceDraft {
  const ServiceDraft({
    this.serviceId,
    required this.code,
    required this.name,
    this.description = '',
    required this.unitPrice,
    this.purchasePrice = 0,
  });

  final int? serviceId;
  final String code;
  final String name;
  final String description;
  final double unitPrice;
  final double purchasePrice;

  bool get isNew => serviceId == null;
}
