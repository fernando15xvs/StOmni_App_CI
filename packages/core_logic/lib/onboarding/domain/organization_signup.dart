enum OrganizationSignupStateKind {
  eligible,
  attached,
  selectionRequired,
  accessRevoked,
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
      'selection_required' => OrganizationSignupStateKind.selectionRequired,
      'access_revoked' => OrganizationSignupStateKind.accessRevoked,
      'legacy_identity_requires_migration' =>
        OrganizationSignupStateKind.legacyIdentityRequiresMigration,
      _ => throw FormatException(
        'Estado de alta de empresa desconocido: $rawState',
      ),
    };
    // Ambiguous and revoked identities never surface company identifiers.
    final attached = kind == OrganizationSignupStateKind.attached;
    return OrganizationSignupState(
      kind: kind,
      eligible:
          kind == OrganizationSignupStateKind.eligible &&
          json['eligible'] == true,
      organizationId: attached ? json['organization_id'] as String? : null,
      organizationStatus: attached
          ? json['organization_status'] as String?
          : null,
      membershipStatus: attached ? json['membership_status'] as String? : null,
      displayName: attached ? json['display_name'] as String? : null,
    );
  }
}

/// Read-only candidate: server-side membership validation remains mandatory
/// on every operational request. The client cannot grant itself this role.
class OrganizationMembership {
  const OrganizationMembership({
    required this.organizationId,
    required this.displayName,
    required this.baseRole,
  });

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  final String organizationId;
  final String displayName;
  final String baseRole;

  factory OrganizationMembership.fromJson(Map<String, dynamic> json) {
    final id = json['organization_id'];
    final name = json['display_name'];
    final role = json['base_role'];
    if (id is! String ||
        !_uuidPattern.hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        role is! String ||
        (role != 'admin' && role != 'operador')) {
      throw const FormatException('La membresía de empresa es inválida.');
    }
    return OrganizationMembership(
      organizationId: id,
      displayName: name,
      baseRole: role,
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
