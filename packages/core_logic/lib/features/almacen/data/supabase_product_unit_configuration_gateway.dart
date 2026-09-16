import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../errors/user_facing_exception.dart';
import '../application/product_unit_configuration_gateway.dart';
import '../domain/commercial_presentation.dart';
import '../domain/product_unit_configuration.dart';
import 'product_unit_configuration_mapper.dart';

class SupabaseProductUnitConfigurationGateway
    implements ProductUnitConfigurationGateway {
  const SupabaseProductUnitConfigurationGateway(this.client);

  final SupabaseClient client;

  String _requireUser() =>
      client.auth.currentUser?.id ??
      (throw const UserFacingException(
        'Inicia sesión para cargar las presentaciones.',
      ));

  void _checkUser(String user) {
    if (client.auth.currentUser?.id != user) {
      throw const UserFacingException('La sesión cambió durante la operación.');
    }
  }

  Future<({bool supported, Map<int, ProductUnitConfiguration> profiles})>
  _loadMany(List<int> ids) async {
    final user = _requireUser();
    try {
      final raw = await client
          .rpc('get_product_unit_profiles_v1', params: {'p_product_ids': ids})
          .timeout(const Duration(seconds: 15));
      _checkUser(user);
      if (raw is! List) {
        throw const FormatException('Respuesta de unidades inválida.');
      }
      final result = <int, ProductUnitConfiguration>{};
      for (final row in raw) {
        if (row is! Map ||
            row['product_id'] is! num ||
            row['product_id'] != (row['product_id'] as num).round()) {
          throw const FormatException('Producto de configuración inválido.');
        }
        final id = (row['product_id'] as num).toInt();
        if (!ids.contains(id) || result.containsKey(id)) {
          throw const FormatException(
            'La configuración no coincide con el catálogo.',
          );
        }
        result[id] = ProductUnitConfigurationMapper.decodeNullable(row)!;
      }
      return (supported: true, profiles: result);
    } on PostgrestException catch (error) {
      _checkUser(user);
      if (error.code == 'PGRST202' &&
          error.message.contains('get_product_unit_profiles_v1')) {
        return (supported: false, profiles: <int, ProductUnitConfiguration>{});
      }
      rethrow;
    }
  }

  @override
  Future<ProductUnitSettings> load(int productId) async {
    final result = await _loadMany([productId]);
    return ProductUnitSettings(
      supported: result.supported,
      configuration: result.profiles[productId],
    );
  }

  Future<List<Map<String, dynamic>>> attach(
    List<Map<String, dynamic>> products,
  ) async {
    if (products.isEmpty) return products;
    final profiles = <int, ProductUnitConfiguration>{};
    for (var start = 0; start < products.length; start += 1000) {
      final end = (start + 1000).clamp(0, products.length).toInt();
      final batch = products.sublist(start, end);
      final result = await _loadMany(
        batch.map((row) => (row['id'] as num).toInt()).toList(),
      );
      if (!result.supported) return products;
      profiles.addAll(result.profiles);
    }
    return products
        .map((row) {
          final configuration = profiles[(row['id'] as num).toInt()];
          return <String, dynamic>{
            ...row,
            'unit_configuration': configuration == null
                ? null
                : ProductUnitConfigurationMapper.encode(configuration),
          };
        })
        .toList(growable: false);
  }

  @override
  Future<ProductUnitConfiguration> save({
    required int productId,
    required int expectedRevision,
    required ProductUnitProfile profile,
  }) async {
    final user = _requireUser();
    PresentationPolicy.validate(profile);
    final encoded = ProductUnitConfigurationMapper.encodeProfile(profile);
    try {
      final raw = await client.rpc(
        'save_product_unit_profile_v6',
        params: {
          'p_product_id': productId,
          'p_expected_revision': expectedRevision,
          'p_profile': encoded,
        },
      );
      _checkUser(user);
      return ProductUnitConfigurationMapper.decodeNullable(raw) ??
          (throw const FormatException('No se recibió el perfil guardado.'));
    } on PostgrestException catch (error) {
      _checkUser(user);
      if (error.code == '40001') {
        throw const UserFacingException(
          'El producto cambió en otro equipo. Recarga antes de guardar.',
        );
      }
      if (error.code == 'PGRST202' &&
          error.message.contains('save_product_unit_profile_v6')) {
        IntegerPresentationPolicy.validate(profile);
        final legacyRaw = await client.rpc(
          'save_product_unit_profile_v1',
          params: {
            'p_product_id': productId,
            'p_expected_revision': expectedRevision,
            'p_profile': encoded,
          },
        );
        _checkUser(user);
        return ProductUnitConfigurationMapper.decodeNullable(legacyRaw) ??
            (throw const FormatException('No se recibió el perfil guardado.'));
      }
      rethrow;
    }
  }
}
