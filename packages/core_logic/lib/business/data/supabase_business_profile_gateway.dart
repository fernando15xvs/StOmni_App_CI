import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../errors/user_facing_exception.dart';
import '../../utils/error_mapper.dart';
import '../application/business_profile_gateway.dart';
import '../domain/business_profile.dart';
import '../domain/cached_business_profile.dart';
import 'business_profile_mapper.dart';

/// Adaptador de perfil empresarial. El backend resuelve el tenant desde auth.uid().
class SupabaseBusinessProfileGateway implements BusinessProfileGateway {
  const SupabaseBusinessProfileGateway(
    this.client, {
    required this.cacheNamespace,
  });
  final SupabaseClient client;
  final String cacheNamespace;
  static const _timeout = Duration(seconds: 10);

  String _user() {
    final user = client.auth.currentUser?.id;
    if (user == null || user.isEmpty) {
      throw const UserFacingException(
        'Inicia sesión para consultar el negocio.',
      );
    }
    return user;
  }

  void _checkUser(String expected) {
    if (client.auth.currentUser?.id != expected) {
      throw const UserFacingException('La sesión cambió durante la operación.');
    }
  }

  /// V1 mantiene una sola organización por auth user. No se añade un ID de
  /// negocio fijo a la clave; el backend determina el tenant efectivo.
  String _cacheKey(String user) => 'business_profile_v2:$cacheNamespace:$user';

  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async {
    final user = _user();
    try {
      final raw = await client.rpc('get_business_profile_v1').timeout(_timeout);
      if (raw is! Map) {
        throw const FormatException('Respuesta de negocio inválida.');
      }
      final profile = BusinessProfileMapper.decode(
        Map<String, dynamic>.from(raw),
      );
      _checkUser(user);
      await _cache(user, profile);
      _checkUser(user);
      return profile;
    } catch (error) {
      _checkUser(user);
      if (!allowOffline || !ErrorMapper.isConnectionError(error)) rethrow;
      final cached = await _readCache(user);
      _checkUser(user);
      if (cached == null) {
        throw const UserFacingException(
          'Conéctate para actualizar las capacidades del negocio antes de vender offline.',
        );
      }
      return cached;
    }
  }

  @override
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  }) async {
    final user = _user();
    if (businessId.trim().isEmpty || !capabilities.supportedByCurrentBackend) {
      throw const UserFacingException(
        'Configuración de negocio no compatible.',
      );
    }

    final Object? raw;
    try {
      raw = await client
          .rpc(
            'update_business_capabilities_v1',
            params: {
              'p_expected_revision': expectedRevision,
              'p_capabilities': BusinessProfileMapper.encodeCapabilities(
                capabilities,
              ),
            },
          )
          .timeout(_timeout);
    } on PostgrestException catch (error) {
      if (error.code == '40001') {
        throw const UserFacingException(
          'La configuración cambió en otro dispositivo. Recarga antes de guardar.',
        );
      }
      rethrow;
    }

    _checkUser(user);
    if (raw is! Map) {
      throw const FormatException('Respuesta de negocio inválida.');
    }
    final profile = BusinessProfileMapper.decode(
      Map<String, dynamic>.from(raw),
    );

    // El ID aportado por la capa de dominio no determina el tenant, pero una
    // respuesta que cambia de perfil dentro de la misma operación indica estado
    // obsoleto o una sesión diferente y no debe aceptarse silenciosamente.
    if (profile.businessId != businessId.trim()) {
      throw const UserFacingException(
        'El perfil empresarial cambió. Recarga antes de guardar.',
      );
    }

    await _cache(user, profile);
    _checkUser(user);
    return profile;
  }

  Future<void> _cache(String user, BusinessProfile profile) async {
    if (cacheNamespace.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey(user),
        jsonEncode({
          'cached_at': DateTime.now().toUtc().toIso8601String(),
          'profile': BusinessProfileMapper.encode(profile),
        }),
      );
    } catch (_) {
      // Escritura remota confirmada; no se convierte en fallo ni se reintenta.
    }
  }

  Future<BusinessProfile?> _readCache(String user) async {
    if (cacheNamespace.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(user));
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.parse(map['cached_at'] as String).toUtc();
      final now = DateTime.now().toUtc();
      final profile = BusinessProfileMapper.decode(
        Map<String, dynamic>.from(map['profile'] as Map),
      );
      final cached = CachedBusinessProfile(profile: profile, cachedAt: at);
      return cached.isCurrentAt(now) ? profile : null;
    } catch (_) {
      return null;
    }
  }
}
