import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/application/tenant_request_scope.dart';

/// Staged I3 catalog cache for one Auth identity and one tenant.
/// Existing 'catalogo_cache' is never imported automatically because its
/// company provenance cannot be trusted once multi-membership is enabled.
final class TenantCatalogCache {
  TenantCatalogCache({
    required this.scope,
    required this.currentAuthUserId,
    required this.currentSelectedOrganizationId,
  });

  final TenantRequestScope scope;
  final String? Function() currentAuthUserId;
  final String? Function() currentSelectedOrganizationId;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String storageKeyFor(String authUserId, String organizationId) {
    if (!_uuid.hasMatch(authUserId) || !_uuid.hasMatch(organizationId)) {
      throw const FormatException('Identificador tenant inválido.');
    }
    return 'catalogo_cache_v2:${authUserId.toLowerCase()}:'
        '${organizationId.toLowerCase()}';
  }

  String get _key => storageKeyFor(scope.authUserId, scope.organizationId);

  Future<T> _withinSession<T>(Future<T> Function() operation) =>
      scope.execute<T>(
        currentAuthUserId: currentAuthUserId,
        currentSelectedOrganizationId: currentSelectedOrganizationId,
        request: (_) => operation(),
      );

  void _requireOwnProduct(Map<String, dynamic> product) {
    if (product['organization_id']?.toString() != scope.organizationId) {
      throw StateError('El producto no pertenece a la empresa seleccionada.');
    }
  }

  Future<void> save(List<Map<String, dynamic>> products) =>
      _withinSession(() async {
        for (final product in products) {
          _requireOwnProduct(product);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _key,
          jsonEncode({
            'schema_version': 2,
            'auth_user_id': scope.authUserId,
            'organization_id': scope.organizationId,
            'items': products,
          }),
        );
      });

  Future<List<Map<String, dynamic>>> load() => _withinSession(() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Catálogo tenant inválido.');
    }
    final envelope = Map<String, dynamic>.from(decoded);
    if (envelope['schema_version'] != 2 ||
        envelope['auth_user_id'] != scope.authUserId ||
        envelope['organization_id'] != scope.organizationId ||
        envelope['items'] is! List) {
      throw const FormatException('El catálogo no coincide con el tenant.');
    }
    final result = <Map<String, dynamic>>[];
    for (final item in envelope['items'] as List) {
      if (item is! Map) {
        throw const FormatException('Registro de catálogo inválido.');
      }
      final product = Map<String, dynamic>.from(item);
      _requireOwnProduct(product);
      result.add(product);
    }
    return List<Map<String, dynamic>>.unmodifiable(result);
  });

  Future<void> clearSelectedTenant() => _withinSession(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  });
}
