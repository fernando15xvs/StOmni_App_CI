import 'package:supabase_flutter/supabase_flutter.dart';

import '../../errors/user_facing_exception.dart';
import '../../onboarding/application/tenant_request_scope.dart';
import '../application/business_profile_gateway.dart';
import '../domain/business_profile.dart';
import 'business_profile_mapper.dart';

/// I3 staged, network-only business profile. Unlike the single-tenant v2
/// gateway, it never reads or writes a user-only SharedPreferences cache.
/// Request headers are scoped to each individual RPC builder.
final class TenantBusinessProfileGateway implements BusinessProfileGateway {
  const TenantBusinessProfileGateway(
    this.client, {
    required this.scope,
    required this.currentSelectedOrganizationId,
  });

  final SupabaseClient client;
  final TenantRequestScope scope;
  final String? Function() currentSelectedOrganizationId;

  static const _timeout = Duration(seconds: 15);

  Future<T> _withSelectedTenant<T>(
    Future<T> Function(String organizationId) request,
  ) => scope.execute<T>(
    currentAuthUserId: () => client.auth.currentUser?.id,
    currentSelectedOrganizationId: currentSelectedOrganizationId,
    request: (organizationId) async {
      final context = await client
          .rpc('get_my_tenant_context_v1')
          .setHeader(TenantRequestScope.organizationHeader, organizationId)
          .timeout(_timeout);
      VerifiedTenantRequestContext.fromServer(
        context,
        requestedOrganizationId: organizationId,
      );
      return request(organizationId);
    },
  );

  /// A business_id identifies configuracion_negocio, not organizations.
  /// Validate the separate organization_id returned by the server before
  /// interpreting the business profile, including after an UPDATE response.
  static BusinessProfile decodeSelectedBusiness(
    Object? raw, {
    required String organizationId,
  }) {
    if (raw is! Map) {
      throw const FormatException('Perfil empresarial inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    if (map['organization_id'] != organizationId) {
      throw StateError('Perfil de otra empresa: operación rechazada.');
    }
    return BusinessProfileMapper.decode(map);
  }

  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async {
    if (allowOffline) {
      throw const UserFacingException(
        'El perfil empresarial multiempresa exige conexión y autorización.',
      );
    }
    return _withSelectedTenant((organizationId) async {
      final result = await client
          .rpc('get_business_profile_v1')
          .setHeader(TenantRequestScope.organizationHeader, organizationId)
          .timeout(_timeout);
      return decodeSelectedBusiness(result, organizationId: organizationId);
    });
  }

  @override
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  }) async {
    if (businessId.trim().isEmpty ||
        expectedRevision < 0 ||
        !capabilities.supportedByCurrentBackend) {
      throw const UserFacingException('Configuración empresarial inválida.');
    }
    return _withSelectedTenant((organizationId) async {
      final Object? result;
      try {
        result = await client
            .rpc(
              'update_business_capabilities_v1',
              params: {
                'p_expected_revision': expectedRevision,
                'p_capabilities': BusinessProfileMapper.encodeCapabilities(
                  capabilities,
                ),
              },
            )
            .setHeader(TenantRequestScope.organizationHeader, organizationId)
            .timeout(_timeout);
      } on PostgrestException catch (error) {
        if (error.code == '40001') {
          throw const UserFacingException(
            'La configuración cambió en otro dispositivo. Recarga antes de guardar.',
          );
        }
        rethrow;
      }
      final profile = decodeSelectedBusiness(
        result,
        organizationId: organizationId,
      );
      if (profile.businessId != businessId.trim()) {
        throw StateError('El perfil empresarial cambió durante la operación.');
      }
      return profile;
    });
  }
}
