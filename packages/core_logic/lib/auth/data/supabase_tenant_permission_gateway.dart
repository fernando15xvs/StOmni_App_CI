import 'package:supabase_flutter/supabase_flutter.dart';

import '../../onboarding/application/tenant_request_scope.dart';
import '../application/tenant_operation_authorizer.dart';

/// Read-only staged I3 permission source. Every RPC has a request-local
/// tenant header; database functions independently verify the Auth JWT.
final class SupabaseTenantPermissionGateway {
  const SupabaseTenantPermissionGateway(
    this.client, {
    required this.currentSelectedOrganizationId,
  });

  final SupabaseClient client;
  final String? Function() currentSelectedOrganizationId;

  Future<TenantVerifiedPermissions> verify(TenantRequestScope scope) =>
      scope.execute<TenantVerifiedPermissions>(
        currentAuthUserId: () => client.auth.currentUser?.id,
        currentSelectedOrganizationId: currentSelectedOrganizationId,
        request: (organizationId) async {
          final contextPayload = await client
              .rpc('get_my_tenant_context_v1')
              .setHeader(TenantRequestScope.organizationHeader, organizationId);
          final tenant = VerifiedTenantRequestContext.fromServer(
            contextPayload,
            requestedOrganizationId: organizationId,
          );
          final effectivePayload = await client
              .rpc('get_my_effective_permissions_v1')
              .setHeader(TenantRequestScope.organizationHeader, organizationId);
          return TenantVerifiedPermissions.fromServer(tenant, effectivePayload);
        },
      );

}
