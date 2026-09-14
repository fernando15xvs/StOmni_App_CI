import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/organization_signup_gateway.dart';
import '../application/organization_signup_use_case.dart';
import '../data/supabase_organization_signup_gateway.dart';
import '../domain/organization_signup.dart';

final organizationSignupGatewayProvider = Provider<OrganizationSignupGateway>(
  (ref) => SupabaseOrganizationSignupGateway(ref.watch(supabaseProvider)),
);

final organizationSignupUseCaseProvider = Provider<OrganizationSignupUseCase>(
  (ref) => OrganizationSignupUseCase(
    ref.watch(organizationSignupGatewayProvider),
  ),
);

/// La elegibilidad pre-tenant pertenece exclusivamente a la sesión Auth actual.
final organizationSignupStateProvider =
    FutureProvider.autoDispose<OrganizationSignupState>(
      (ref) => ref.watch(organizationSignupUseCaseProvider).getState(),
    );
