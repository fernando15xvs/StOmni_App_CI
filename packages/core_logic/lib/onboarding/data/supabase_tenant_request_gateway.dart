import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/tenant_request_scope.dart';

/// Read-only I3 request bridge. Unlike mutating SupabaseClient.headers, this
/// selector exists exclusively on one PostgREST builder. It cannot leak into
/// a parallel tab, a second client session or unrelated API operations.
///
/// Deliberately not connected to business writes or Home until I3/I4 gates.
class SupabaseTenantRequestGateway {
  const SupabaseTenantRequestGateway(
    this.client, {
    required this.currentSelectedOrganizationId,
  });

  final SupabaseClient client;
  final String? Function() currentSelectedOrganizationId;

  Future<VerifiedTenantRequestContext> validateSelectedTenant(
    TenantRequestScope scope,
  ) async {
    return scope.execute<VerifiedTenantRequestContext>(
      currentAuthUserId: () => client.auth.currentUser?.id,
      currentSelectedOrganizationId: currentSelectedOrganizationId,
      request: (organizationId) async {
        // Header is a selection request, NOT a permission. Server RPC
        // validates active member, employee, company and the exact JWT actor.
        final payload = await client
            .rpc('get_my_tenant_context_v1')
            .setHeader(
              TenantRequestScope.organizationHeader,
              organizationId,
            )
            .timeout(const Duration(seconds: 15));
        return VerifiedTenantRequestContext.fromServer(
          payload,
          requestedOrganizationId: organizationId,
        );
      },
    );
  }
}
