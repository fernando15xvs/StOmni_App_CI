class SalePriceQuote {
  const SalePriceQuote({
    required this.productId,
    required this.presentationCode,
    required this.quantity,
    required this.catalogPrice,
    required this.price,
    this.ruleId,
    this.ruleName,
  });

  final int productId;
  final String presentationCode;
  final double quantity;
  final double catalogPrice;
  final double price;
  final int? ruleId;
  final String? ruleName;

  bool get hasRule => ruleId != null;
  double get discountAmount => catalogPrice > price ? catalogPrice - price : 0;
  double get discountPercent =>
      catalogPrice <= 0 ? 0 : (discountAmount / catalogPrice) * 100;
}

class SalePriceRule {
  const SalePriceRule({
    required this.id,
    required this.name,
    required this.productId,
    required this.productName,
    required this.minQuantity,
    required this.priority,
    required this.active,
    this.presentationCode,
    this.fixedPrice,
    this.discountPercent,
    this.startsAt,
    this.endsAt,
  });

  final int id;
  final String name;
  final int productId;
  final String productName;
  final String? presentationCode;
  final double minQuantity;
  final double? fixedPrice;
  final double? discountPercent;
  final int priority;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool active;
}

class SalePriceRuleDraft {
  const SalePriceRuleDraft({
    required this.name,
    required this.productId,
    required this.minQuantity,
    required this.priority,
    required this.active,
    this.presentationCode,
    this.fixedPrice,
    this.discountPercent,
    this.startsAt,
    this.endsAt,
  });

  final String name;
  final int productId;
  final String? presentationCode;
  final double minQuantity;
  final double? fixedPrice;
  final double? discountPercent;
  final int priority;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool active;
}
