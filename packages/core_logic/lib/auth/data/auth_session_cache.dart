import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/app_roles.dart';
import '../domain/app_permission.dart';
import '../domain/session_authorization.dart';

class AuthSessionSnapshot {
  AuthSessionSnapshot({
    required this.authUserId,
    required this.role,
    required this.validatedAt,
    required Iterable<AppPermission> permissions,
  }) : permissions = Set<AppPermission>.unmodifiable(permissions);

  final String authUserId;
  final String role;
  final String validatedAt;
  final Set<AppPermission> permissions;

  Map<String, dynamic> toMap() => {
    'schema_version': 2,
    'auth_user_id': authUserId,
    'role': role,
    'validated_at': validatedAt,
    'permissions': permissions.map((permission) => permission.code).toList()
      ..sort(),
  };
}

/// Snapshot local mínimo de una autorización que ya fue validada online.
///
/// No guarda contraseña, access token ni refresh token. Desde v2 guarda también
/// el conjunto efectivo de permisos para que un override restrictivo no se pierda
/// cuando el dispositivo trabaja temporalmente sin conexión.
abstract final class AuthSessionCache {
  static const String _key = 'auth_validated_session_v2';
  static const String _legacyKey = 'auth_validated_session_v1';

  static const offlineAuthorizationTtl =
      CachedSessionAuthorization.offlineAuthorizationTtl;
  static const _maxFutureClockSkew =
      CachedSessionAuthorization.maxFutureClockSkew;

  static Future<void> saveValidatedSession({
    required String authUserId,
    required String role,
    required Iterable<AppPermission> permissions,
    DateTime? validatedAtUtc,
  }) async {
    final userId = authUserId.trim();
    final normalizedRole = AppRoles.normalize(role);
    final permissionSet = Set<AppPermission>.from(permissions);
    final base = RolePermissionPolicy.forRole(normalizedRole);
    if (userId.isEmpty ||
        normalizedRole == null ||
        !base.containsAll(permissionSet)) {
      throw ArgumentError(
        'La sesión validada requiere usuario, rol y permisos válidos.',
      );
    }

    final snapshot = AuthSessionSnapshot(
      authUserId: userId,
      role: normalizedRole,
      permissions: permissionSet,
      validatedAt: (validatedAtUtc ?? DateTime.now()).toUtc().toIso8601String(),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(snapshot.toMap()));
    await prefs.remove(_legacyKey);
  }

  static Future<AuthSessionSnapshot?> loadForUser(
    String authUserId, {
    DateTime? nowUtc,
  }) async {
    final userId = authUserId.trim();
    if (userId.isEmpty) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final map = Map<String, dynamic>.from(decoded);
      if ((map['schema_version'] as num?)?.toInt() != 2) return null;
      final cachedUserId = map['auth_user_id']?.toString().trim() ?? '';
      final normalizedRole = AppRoles.normalize(map['role']?.toString());
      final validatedAtRaw = map['validated_at']?.toString().trim() ?? '';
      final validatedAt = DateTime.tryParse(validatedAtRaw)?.toUtc();
      final permissionRows = map['permissions'];
      if (cachedUserId != userId ||
          normalizedRole == null ||
          validatedAt == null ||
          permissionRows is! List) {
        return null;
      }

      final permissions = AppPermission.decodeCodes(permissionRows);
      final base = RolePermissionPolicy.forRole(normalizedRole);
      if (!base.containsAll(permissions)) return null;

      final now = (nowUtc ?? DateTime.now()).toUtc();
      if (validatedAt.isAfter(now.add(_maxFutureClockSkew))) return null;
      if (!validatedAt.add(offlineAuthorizationTtl).isAfter(now)) return null;

      return AuthSessionSnapshot(
        authUserId: cachedUserId,
        role: normalizedRole,
        validatedAt: validatedAt.toIso8601String(),
        permissions: permissions,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_legacyKey);
  }
}
