import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../errors/user_facing_exception.dart';
import '../../utils/error_mapper.dart';
import '../application/business_branding_gateway.dart';
import '../domain/business_branding.dart';
import '../domain/cached_business_branding.dart';
import 'business_branding_mapper.dart';

/// Lee la marca desde `configuracion_negocio` exclusivamente por la RPC que
/// resuelve el tenant actual desde Auth. Nunca acepta `organization_id`.
class SupabaseBusinessBrandingGateway implements BusinessBrandingGateway {
  const SupabaseBusinessBrandingGateway(
    this.client, {
    required this.cacheNamespace,
  });

  static const _timeout = Duration(seconds: 10);

  final SupabaseClient client;
  final String cacheNamespace;

  String _user() {
    final user = client.auth.currentUser?.id;
    if (user == null || user.isEmpty) {
      throw const UserFacingException('Inicia sesión para consultar la marca.');
    }
    return user;
  }

  void _checkUser(String expected) {
    if (client.auth.currentUser?.id != expected) {
      throw const UserFacingException('La sesión cambió durante la operación.');
    }
  }

  String _cacheKey(String user) =>
      'business_branding_v1:$cacheNamespace:$user';

  @override
  Future<BusinessBranding> load({bool allowOffline = false}) async {
    final user = _user();
    try {
      final raw = await client
          .rpc('get_current_business_configuration_v1')
          .timeout(_timeout);
      if (raw is! Map) {
        throw const FormatException('Respuesta de branding inválida.');
      }
      final branding = BusinessBrandingMapper.decode(
        Map<String, dynamic>.from(raw),
      );
      _checkUser(user);
      await _cache(user, branding);
      _checkUser(user);
      return branding;
    } catch (error) {
      _checkUser(user);
      if (!allowOffline || !ErrorMapper.isConnectionError(error)) rethrow;
      final cached = await _readCache(user);
      _checkUser(user);
      if (cached == null) {
        throw const UserFacingException(
          'Conéctate para cargar la identidad visual de tu empresa.',
        );
      }
      return cached;
    }
  }

  Future<void> _cache(String user, BusinessBranding branding) async {
    if (cacheNamespace.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey(user),
        jsonEncode({
          'cached_at': DateTime.now().toUtc().toIso8601String(),
          'branding': BusinessBrandingMapper.encode(branding),
        }),
      );
    } catch (_) {
      // Una lectura remota válida no falla por no poder persistir su snapshot.
    }
  }

  Future<BusinessBranding?> _readCache(String user) async {
    if (cacheNamespace.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(user));
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(map['cached_at'] as String).toUtc();
      final branding = BusinessBrandingMapper.decode(
        Map<String, dynamic>.from(map['branding'] as Map),
      );
      final cached = CachedBusinessBranding(
        branding: branding,
        cachedAt: cachedAt,
      );
      return cached.isCurrentAt(DateTime.now().toUtc()) ? branding : null;
    } catch (_) {
      return null;
    }
  }
}
