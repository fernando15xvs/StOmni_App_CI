import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/organization_signup_gateway.dart';
import '../domain/organization_signup.dart';

class SupabaseOrganizationSignupGateway implements OrganizationSignupGateway {
  const SupabaseOrganizationSignupGateway(this.client);

  final SupabaseClient client;

  @override
  Future<OrganizationSignupState> getState() async {
    final raw = await client.rpc('get_organization_signup_state_v1');
    if (raw is! Map) {
      throw const FormatException('El estado de alta de empresa es inválido.');
    }
    return OrganizationSignupState.fromJson(Map<String, dynamic>.from(raw));
  }

  @override
  Future<OrganizationSignupResult> createOrganization(
    OrganizationSignupRequest request,
  ) async {
    final raw = await client.rpc(
      'create_my_organization_v1',
      params: <String, dynamic>{
        'p_display_name': request.displayName,
        'p_country_code': request.countryCode,
        'p_currency_code': request.currencyCode,
        'p_timezone': request.timezone,
        'p_legal_name': request.legalName,
      },
    );
    if (raw is! Map) {
      throw const FormatException('El resultado del alta de empresa es inválido.');
    }
    return OrganizationSignupResult.fromJson(Map<String, dynamic>.from(raw));
  }
}
