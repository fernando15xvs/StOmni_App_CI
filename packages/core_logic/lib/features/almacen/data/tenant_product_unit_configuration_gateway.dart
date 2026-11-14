import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../errors/user_facing_exception.dart';
import '../../../onboarding/application/tenant_request_scope.dart';
import '../application/product_unit_configuration_gateway.dart';
import '../domain/commercial_presentation.dart';
import '../domain/product_unit_configuration.dart';
import 'product_unit_configuration_mapper.dart';

/// Prepared I3 product-unit gateway. Reads and writes are scoped to the
/// selected tenant through individual RPC builders. No global client header,
/// cross-tenant in-memory lookup, or unbound offline cache is used.
///
/// The server filters get_product_unit_profiles_v1 by current organization
/// and checks tenant ownership in save_product_unit_profile_v6.
final class TenantProductUnitConfigurationGateway
    implements ProductUnitConfigurationGateway {
  const TenantProductUnitConfigurationGateway(
    this.client, {
    required this.scope,
    required this.currentSelectedOrganizationId,
  });

  final SupabaseClient client;
  final TenantRequestScope scope;
  final String? Function() currentSelectedOrganizationId;

  static const _timeout = Duration(seconds: 15);

  Future<T> _withSelectedTenant<T>(
    Future<T> Function(String organizationId) operation,
  ) => scope.execute<T>(
    currentAuthUserId: () => client.auth.currentUser?.id,
    currentSelectedOrganizationId: currentSelectedOrganizationId,
    request: (organizationId) async {
      final response = await client
          .rpc('get_my_tenant_context_v1')
          .setHeader(TenantRequestScope.organizationHeader, organizationId)
          .timeout(_timeout);
      VerifiedTenantRequestContext.fromServer(
        response,
        requestedOrganizationId: organizationId,
      );
      return operation(organizationId);
    },
  );

  /// The profile RPC does not include organization_id in its rows: tenant
  /// ownership is verified by the server. Additionally reject any response
  /// outside the explicitly requested product ID set, duplicate, or corrupt
  /// product. Never merge profiles from a different request/window.
  static Map<int, ProductUnitConfiguration> decodeRequestedProfiles(
    Object? response, {
    required Set<int> requestedProductIds,
  }) {
    if (requestedProductIds.any((id) => id <= 0) || response is! List) {
      throw const FormatException('Respuesta de inventario inválida.');
    }

    final profiles = <int, ProductUnitConfiguration>{};
    for (final raw in response) {
      if (raw is! Map ||
          raw['product_id'] is! num ||
          raw['product_id'] != (raw['product_id'] as num).round()) {
        throw const FormatException('Identificador de producto inválido.');
      }
      final id = (raw['product_id'] as num).toInt();
      if (!requestedProductIds.contains(id) || profiles.containsKey(id)) {
        throw StateError('Perfil de inventario ajeno o duplicado.');
      }
      final decoded = ProductUnitConfigurationMapper.decodeNullable(raw);
      if (decoded == null) {
        throw const FormatException('Perfil de inventario vacío.');
      }
      profiles[id] = decoded;
    }
    return Map<int, ProductUnitConfiguration>.unmodifiable(profiles);
  }

  @override
  Future<ProductUnitSettings> load(int productId) async {
    if (productId <= 0) {
      throw ArgumentError.value(productId, 'productId');
    }

    return _withSelectedTenant((organizationId) async {
      final response = await client
          .rpc(
            'get_product_unit_profiles_v1',
            params: {
              'p_product_ids': [productId],
            },
          )
          .setHeader(TenantRequestScope.organizationHeader, organizationId)
          .timeout(_timeout);
      final profiles = decodeRequestedProfiles(
        response,
        requestedProductIds: {productId},
      );
      return ProductUnitSettings(
        supported: true,
        configuration: profiles[productId],
      );
    });
  }

  @override
  Future<ProductUnitConfiguration> save({
    required int productId,
    required int expectedRevision,
    required ProductUnitProfile profile,
  }) async {
    if (productId <= 0 || expectedRevision < 0) {
      throw ArgumentError('Producto o revisión inválida.');
    }
    PresentationPolicy.validate(profile);
    return _withSelectedTenant((organizationId) async {
      final Object? response;
      try {
        response = await client
            .rpc(
              'save_product_unit_profile_v6',
              params: {
                'p_product_id': productId,
                'p_expected_revision': expectedRevision,
                'p_profile': ProductUnitConfigurationMapper.encodeProfile(
                  profile,
                ),
              },
            )
            .setHeader(TenantRequestScope.organizationHeader, organizationId)
            .timeout(_timeout);
      } on PostgrestException catch (error) {
        if (error.code == '40001') {
          throw const UserFacingException(
            'El producto cambió. Recarga antes de guardar.',
          );
        }
        rethrow;
      }
      if (response is Map &&
          response.containsKey('product_id') &&
          response['product_id'] != productId) {
        throw StateError('El servidor devolvió un producto diferente.');
      }
      return ProductUnitConfigurationMapper.decodeNullable(response) ??
          (throw const FormatException('El servidor no devolvió el perfil.'));
    });
  }
}
