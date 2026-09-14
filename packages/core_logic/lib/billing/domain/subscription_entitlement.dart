enum SubscriptionEntitlementKind { feature, limit }

class SubscriptionEntitlement {
  const SubscriptionEntitlement({
    required this.key,
    required this.kind,
    required this.enabled,
    this.limitValue,
    this.unit,
  });

  final String key;
  final SubscriptionEntitlementKind kind;
  final bool enabled;
  final int? limitValue;
  final String? unit;

  factory SubscriptionEntitlement.fromJson(Map<String,dynamic> json) {
    final key=json['key']?.toString()??'';
    final rawKind=json['kind']?.toString()??'';
    final kind=switch(rawKind){'feature'=>SubscriptionEntitlementKind.feature,'limit'=>SubscriptionEntitlementKind.limit,_=>null};
    if(key.isEmpty||kind==null) throw const FormatException('Entitlement inválido.');
    return SubscriptionEntitlement(
      key:key,
      kind:kind,
      enabled:json['enabled']==true,
      limitValue:(json['limit_value'] as num?)?.toInt(),
      unit:json['unit']?.toString(),
    );
  }
}
