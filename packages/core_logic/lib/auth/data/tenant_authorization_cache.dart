import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/app_roles.dart';
import '../domain/app_permission.dart';
import '../domain/session_authorization.dart';

/// V3 tenant-bound authorization snapshot. Never re-interpret old v1/v2
/// user-only snapshots as belonging to any selected organization.
class TenantAuthorizationSnapshot {
  TenantAuthorizationSnapshot({
    required this.authUserId,
    required this.organizationId,
    required this.role,
    required this.validatedAt,
    required Iterable<AppPermission> permissions,
  }) : permissions = Set<AppPermission>.unmodifiable(permissions);

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  final String authUserId;
  final String organizationId;
  final String role;
  final DateTime validatedAt;
  final Set<AppPermission> permissions;

  Map<String, dynamic> toMap() => {
    'schema_version': 3,
    'auth_user_id': authUserId,
    'organization_id': organizationId,
    'role': role,
    'validated_at': validatedAt.toUtc().toIso8601String(),
    'permissions': permissions.map((p) => p.code).toList()..sort(),
  };

  static TenantAuthorizationSnapshot fromMap(Map<String, dynamic> map) {
    if (map['schema_version'] != 3 ||
        map['auth_user_id'] is! String ||
        map['organization_id'] is! String ||
        map['role'] is! String ||
        map['validated_at'] is! String ||
        map['permissions'] is! List) {
      throw const FormatException('Snapshot tenant v3 inválido.');
    }
    final timestamp = DateTime.tryParse(map['validated_at'] as String);
    if (timestamp == null) {
      throw const FormatException('Fecha de autorización inválida.');
    }
    final role = AppRoles.normalize(map['role'] as String);
    if (role == null) {
      throw const FormatException('Rol de autorización inválido.');
    }
    final permissions = AppPermission.decodeCodes(map['permissions'] as List);
    if (!RolePermissionPolicy.forRole(role).containsAll(permissions)) {
      throw const FormatException('Permisos mayores al rol validado.');
    }
    final snapshot = TenantAuthorizationSnapshot(
      authUserId: map['auth_user_id'] as String,
      organizationId: map['organization_id'] as String,
      role: role,
      validatedAt: timestamp,
      permissions: permissions,
    );
    if (snapshot.authUserId.isEmpty ||
        !_uuid.hasMatch(snapshot.organizationId)) {
      throw const FormatException('Identidad de autorización inválida.');
    }
    return snapshot;
  }

  bool isValidFor(
    String currentAuthUserId,
    String currentOrganizationId,
    DateTime nowUtc,
  ) {
    final now = nowUtc.toUtc();
    final timestamp = validatedAt.toUtc();
    return authUserId.trim().isNotEmpty &&
        authUserId == currentAuthUserId &&
        organizationId == currentOrganizationId &&
        _uuid.hasMatch(currentOrganizationId) &&
        AppRoles.normalize(role) == role &&
        RolePermissionPolicy.forRole(role).containsAll(permissions) &&
        !timestamp.isAfter(
          now.add(CachedSessionAuthorization.maxFutureClockSkew),
        ) &&
        timestamp
            .add(CachedSessionAuthorization.offlineAuthorizationTtl)
            .isAfter(now);
  }
}

/// Explicitly keyed by (Auth user, organization). This store is STAGED;
/// the legacy online/offline gateway is not switched to v3 until the
/// operational tenant selection and offline DB isolation are certified.
abstract final class TenantAuthorizationCache {
  static const String _prefix = 'auth_validated_session_v3:';

  static String _key(String authUserId, String organizationId) =>
      '$_prefix$authUserId:$organizationId';

  static Future<void> save(TenantAuthorizationSnapshot snapshot) async {
    if (!snapshot.isValidFor(
      snapshot.authUserId,
      snapshot.organizationId,
      DateTime.now().toUtc(),
    )) {
      throw ArgumentError('Autorización tenant expirada o inválida.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(snapshot.authUserId, snapshot.organizationId),
      jsonEncode(snapshot.toMap()),
    );
  }

  static Future<TenantAuthorizationSnapshot?> load({
    required String authUserId,
    required String organizationId,
    DateTime? nowUtc,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(authUserId, organizationId));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final snapshot = TenantAuthorizationSnapshot.fromMap(
        Map<String, dynamic>.from(decoded),
      );
      return snapshot.isValidFor(
            authUserId,
            organizationId,
            nowUtc ?? DateTime.now().toUtc(),
          )
          ? snapshot
          : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearForTenant({
    required String authUserId,
    required String organizationId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(authUserId, organizationId));
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_prefix)) {
        await prefs.remove(key);
      }
    }
  }
}
