import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/error_mapper.dart';
import '../application/validate_session_use_case.dart';
import '../domain/app_permission.dart';
import '../domain/session_authorization.dart';
import 'auth_session_cache.dart';

class SupabaseSessionValidationGateway implements SessionValidationGateway {
  const SupabaseSessionValidationGateway(this.client);

  final SupabaseClient client;

  @override
  String? get currentAuthUserId => client.auth.currentUser?.id;

  @override
  bool get requiresPasswordChange =>
      client.auth.currentUser?.userMetadata?['force_password_change'] == true;

  @override
  Future<String?> readActiveRole(String authUserId) async {
    if (currentAuthUserId != authUserId) return null;
    try {
      final raw = await client
          .rpc('get_my_tenant_context_v1')
          .timeout(const Duration(seconds: 15));
      if (currentAuthUserId != authUserId) return null;
      if (raw is! Map) {
        throw const FormatException('Respuesta de contexto tenant inválida.');
      }
      final context = Map<String, dynamic>.from(raw);
      final organizationId = context['organization_id']?.toString().trim() ?? '';
      final role = context['base_role']?.toString().trim();
      if (organizationId.isEmpty || role == null || role.isEmpty) {
        return null;
      }
      return role;
    } on PostgrestException catch (error) {
      // Una identidad Auth sin membership todavía no posee tenant context. La
      // elegibilidad F8.1 se comprueba de forma separada; no se autoriza aquí.
      if (error.code == '42501' || error.code == 'P0002') {
        return null;
      }
      if (ErrorMapper.isConnectionError(error)) {
        throw const SessionValidationUnavailable();
      }
      rethrow;
    } catch (error) {
      if (ErrorMapper.isConnectionError(error)) {
        throw const SessionValidationUnavailable();
      }
      rethrow;
    }
  }

  @override
  Future<bool> canStartOrganizationSignup(String authUserId) async {
    if (currentAuthUserId != authUserId) return false;
    try {
      final raw = await client
          .rpc('get_organization_signup_state_v1')
          .timeout(const Duration(seconds: 15));
      if (currentAuthUserId != authUserId) return false;
      if (raw is! Map) {
        throw const FormatException('Respuesta de onboarding inválida.');
      }
      final state = Map<String, dynamic>.from(raw);
      return state['state'] == 'eligible' && state['eligible'] == true;
    } catch (error) {
      if (ErrorMapper.isConnectionError(error)) {
        throw const SessionValidationUnavailable();
      }
      rethrow;
    }
  }

  @override
  Future<Set<AppPermission>?> readEffectivePermissions(
    String authUserId,
  ) async {
    if (currentAuthUserId != authUserId) return const <AppPermission>{};
    try {
      final raw = await client
          .rpc('get_my_effective_permissions_v1')
          .timeout(const Duration(seconds: 15));
      if (currentAuthUserId != authUserId) return const <AppPermission>{};
      if (raw is! Map) {
        throw const FormatException('Respuesta de permisos inválida.');
      }
      final map = Map<String, dynamic>.from(raw);
      if (map['supported'] != true || map['permissions'] is! List) {
        throw const FormatException('Contrato de permisos inválido.');
      }
      return AppPermission.decodeCodes(map['permissions'] as List);
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' &&
          error.message.contains('get_my_effective_permissions_v1')) {
        return null;
      }
      if (ErrorMapper.isConnectionError(error)) {
        throw const SessionValidationUnavailable();
      }
      rethrow;
    } catch (error) {
      if (ErrorMapper.isConnectionError(error)) {
        throw const SessionValidationUnavailable();
      }
      rethrow;
    }
  }

  @override
  Future<CachedSessionAuthorization?> readCachedAuthorization(
    String authUserId,
  ) async {
    final snapshot = await AuthSessionCache.loadForUser(authUserId);
    if (snapshot == null) return null;
    final timestamp = DateTime.tryParse(snapshot.validatedAt);
    if (timestamp == null) return null;
    return CachedSessionAuthorization(
      authUserId: snapshot.authUserId,
      role: snapshot.role,
      validatedAt: timestamp,
      permissions: snapshot.permissions,
    );
  }

  @override
  Future<void> saveAuthorization(
    CachedSessionAuthorization authorization,
  ) async {
    if (currentAuthUserId != authorization.authUserId) return;
    await AuthSessionCache.saveValidatedSession(
      authUserId: authorization.authUserId,
      role: authorization.role,
      permissions: authorization.permissions,
      validatedAtUtc: authorization.validatedAt,
    );
  }

  @override
  Future<void> clearCachedAuthorization(String expectedAuthUserId) async {
    if (currentAuthUserId != expectedAuthUserId) return;
    await AuthSessionCache.clear();
  }

  @override
  Future<void> invalidateSession(String expectedAuthUserId) async {
    if (currentAuthUserId != expectedAuthUserId) return;
    try {
      await AuthSessionCache.clear();
    } catch (_) {}
    if (currentAuthUserId != expectedAuthUserId) return;
    await client.auth
        .signOut(scope: SignOutScope.local)
        .timeout(const Duration(seconds: 5));
  }
}
