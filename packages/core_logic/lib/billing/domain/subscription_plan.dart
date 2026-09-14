class SubscriptionPlan {
  const SubscriptionPlan({
    required this.id,
    required this.code,
    required this.displayName,
    required this.description,
    required this.tierRank,
  });

  final String id;
  final String code;
  final String displayName;
  final String description;
  final int tierRank;

  factory SubscriptionPlan.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final code = json['code']?.toString() ?? '';
    final displayName = json['display_name']?.toString() ?? '';
    final description = json['description']?.toString() ?? '';
    final tierRank = (json['tier_rank'] as num?)?.toInt();
    if (id.isEmpty || code.isEmpty || displayName.isEmpty || tierRank == null) {
      throw const FormatException('El plan de suscripción es inválido.');
    }
    return SubscriptionPlan(
      id: id,
      code: code,
      displayName: displayName,
      description: description,
      tierRank: tierRank,
    );
  }
}
