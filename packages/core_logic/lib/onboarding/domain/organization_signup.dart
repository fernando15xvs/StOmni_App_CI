enum OrganizationSignupStateKind {
  eligible,
  attached,
  legacyIdentityRequiresMigration,
}

class OrganizationSignupState {
  const OrganizationSignupState({
    required this.kind,
    required this.eligible,
    this.organizationId,
    this.organizationStatus,
    this.membershipStatus,
    this.displayName,
  });

  final OrganizationSignupStateKind kind;
  final bool eligible;
  final String? organizationId;
  final String? organizationStatus;
  final String? membershipStatus;
  final String? displayName;

  factory OrganizationSignupState.fromJson(Map<String, dynamic> json) {
    final rawState = json['state'] as String?;
    final kind = switch (rawState) {
      'eligible' => OrganizationSignupStateKind.eligible,
      'attached' => OrganizationSignupStateKind.attached,
      'legacy_identity_requires_migration' =>
        OrganizationSignupStateKind.legacyIdentityRequiresMigration,
      _ => throw FormatException(
        'Estado de alta de empresa desconocido: $rawState',
      ),
    };
    return OrganizationSignupState(
      kind: kind,
      eligible: json['eligible'] == true,
      organizationId: json['organization_id'] as String?,
      organizationStatus: json['organization_status'] as String?,
      membershipStatus: json['membership_status'] as String?,
      displayName: json['display_name'] as String?,
    );
  }
}

class OrganizationSignupRequest {
  const OrganizationSignupRequest({
    required this.displayName,
    required this.countryCode,
    required this.currencyCode,
    required this.timezone,
    this.legalName,
  });

  final String displayName;
  final String countryCode;
  final String currencyCode;
  final String timezone;
  final String? legalName;
}

class OrganizationSignupResult {
  const OrganizationSignupResult({
    required this.organizationId,
    required this.displayName,
    required this.countryCode,
    required this.currencyCode,
    required this.timezone,
    required this.membershipRole,
    required this.planCode,
    required this.subscriptionStatus,
    required this.subscriptionRevision,
  });

  final String organizationId;
  final String displayName;
  final String countryCode;
  final String currencyCode;
  final String timezone;
  final String membershipRole;
  final String planCode;
  final String subscriptionStatus;
  final int subscriptionRevision;

  factory OrganizationSignupResult.fromJson(Map<String, dynamic> json) {
    final subscription = json['subscription'];
    if (subscription is! Map) {
      throw const FormatException('La suscripción inicial es inválida.');
    }
    final subscriptionMap = Map<String, dynamic>.from(subscription);
    return OrganizationSignupResult(
      organizationId: json['organization_id'] as String,
      displayName: json['display_name'] as String,
      countryCode: json['country_code'] as String,
      currencyCode: json['currency_code'] as String,
      timezone: json['timezone'] as String,
      membershipRole: json['membership_role'] as String,
      planCode: subscriptionMap['plan_code'] as String,
      subscriptionStatus: subscriptionMap['status'] as String,
      subscriptionRevision: (subscriptionMap['revision'] as num).toInt(),
    );
  }
}
