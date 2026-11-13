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
  (ref) =>
      OrganizationSignupUseCase(ref.watch(organizationSignupGatewayProvider)),
);

/// Key membership candidates by the authenticated user. Never share a
/// previous user's tenant choices across sign-out/sign-in or account change.
final organizationMembershipsForUserProvider = FutureProvider.autoDispose
    .family<List<OrganizationMembership>, String>((ref, authUserId) async {
      final client = ref.watch(supabaseProvider);
      if (authUserId.isEmpty || client.auth.currentUser?.id != authUserId) {
        throw StateError('La sesión cambió. Vuelve a iniciar sesión.');
      }
      final memberships = await ref
          .watch(organizationSignupUseCaseProvider)
          .listMemberships();
      if (client.auth.currentUser?.id != authUserId) {
        throw StateError('La sesión cambió. Vuelve a iniciar sesión.');
      }
      return memberships;
    });

final organizationSignupStateProvider =
    FutureProvider.autoDispose<OrganizationSignupState>(
      (ref) => ref.watch(organizationSignupUseCaseProvider).getState(),
    );
