import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/facturacion/application/business_fiscal_profile_mapper.dart';
import '../features/facturacion/domain/business_fiscal_profile.dart';

class ConfiguracionService {
  static const String _bucketLogos = 'logos';

  static BusinessFiscalProfileKey _activeProfileKey =
      const BusinessFiscalProfileKey(businessId: '');
  static String _activeOrganizationId = '';
  static String _activeAuthUserId = '';

  /// Snapshot JSON histórico. Se conserva únicamente para adaptadores legacy.
  /// Las nuevas interfaces deben consumir [fiscalProfile].
  static Map<String, dynamic>? negocioData;

  static BusinessFiscalProfileKey get activeFiscalProfileKey =>
      _activeProfileKey;

  /// UUID del tenant devuelto por el backend. Nunca se acepta desde la UI como
  /// autoridad; sólo se usa para nombres de objetos Storage del tenant actual.
  static String get activeOrganizationId => _activeOrganizationId;

  /// Vista tipada de la configuración fiscal actual.
  static BusinessFiscalProfile? get fiscalProfile {
    final currentUserId = _client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty || currentUserId != _activeAuthUserId) {
      return null;
    }
    return BusinessFiscalProfileMapper.fromLegacy(negocioData);
  }

  static SupabaseClient get _client => Supabase.instance.client;

  /// Conserva el contrato de selección lógica para consumidores existentes.
  /// El backend sigue resolviendo el único tenant autorizado desde auth.uid().
  static void selectFiscalProfile(BusinessFiscalProfileKey key) {
    final normalized = key.normalized();
    if (!normalized.isValid) {
      throw ArgumentError.value(
        key.businessId,
        'businessId',
        'El perfil fiscal requiere un identificador de negocio.',
      );
    }
    clearActiveConfiguration();
    _activeProfileKey = normalized;
  }

  /// Retira snapshots de identidad fiscal/visual al cambiar la sesión Auth.
  /// No borra datos remotos ni objetos de Storage.
  static void clearActiveConfiguration() {
    _activeProfileKey = const BusinessFiscalProfileKey(businessId: '');
    _activeOrganizationId = '';
    _activeAuthUserId = '';
    negocioData = null;
  }

  /// Carga exclusivamente la configuración perteneciente al tenant autenticado.
  /// No se consulta por un ID suministrado por Flutter.
  static Future<bool> cargarNegocio({BusinessFiscalProfileKey? key}) async {
    final expectedKey = key?.normalized();
    if (expectedKey != null && !expectedKey.isValid) {
      throw ArgumentError.value(
        key?.businessId,
        'businessId',
        'El perfil fiscal requiere un identificador de negocio.',
      );
    }

    final authUserId = _client.auth.currentUser?.id ?? '';
    if (authUserId.isEmpty) {
      clearActiveConfiguration();
      return false;
    }
    if (_activeAuthUserId.isNotEmpty && _activeAuthUserId != authUserId) {
      clearActiveConfiguration();
    }

    try {
      final raw = await _client.rpc('get_current_business_configuration_v1');
      if (_client.auth.currentUser?.id != authUserId) {
        throw StateError('La sesión cambió durante la carga de configuración.');
      }
      if (raw is! Map) {
        throw const FormatException(
          'La configuración del negocio devolvió una respuesta inválida.',
        );
      }

      final configuration = Map<String, dynamic>.from(raw);
      _setActiveConfiguration(configuration, authUserId: authUserId);

      final loadedProfile = fiscalProfile;
      if (loadedProfile == null || !loadedProfile.key.isValid) {
        throw const FormatException(
          'El perfil fiscal no contiene un ID válido.',
        );
      }

      if (expectedKey != null &&
          loadedProfile.businessId != expectedKey.businessId) {
        throw StateError(
          'El perfil solicitado no corresponde al tenant autenticado.',
        );
      }

      return true;
    } catch (e, st) {
      debugPrint('Error cargando configuración del negocio: $e');
      debugPrintStack(stackTrace: st);
      return false;
    }
  }

  /// Entrada tipada para modificar únicamente los campos editables del perfil.
  static Future<bool> actualizarPerfilFiscal(
    BusinessFiscalProfile profile,
  ) async {
    final profileBusinessId = profile.businessId.trim();
    final activeBusinessId = _activeProfileKey.businessId.trim();
    if (profileBusinessId.isNotEmpty &&
        activeBusinessId.isNotEmpty &&
        profileBusinessId != activeBusinessId) {
      throw StateError(
        'El perfil a guardar no corresponde al negocio fiscal activo.',
      );
    }

    return actualizarNegocio(
      BusinessFiscalProfileMapper.toLegacyEditableFields(profile),
    );
  }

  /// Adaptador de escritura del esquema histórico. La RPC resuelve el tenant
  /// desde la sesión y aplica el allowlist fiscal en PostgreSQL.
  static Future<bool> actualizarNegocio(Map<String, dynamic> datos) async {
    final authUserId = _client.auth.currentUser?.id ?? '';
    if (authUserId.isEmpty || authUserId != _activeAuthUserId) {
      clearActiveConfiguration();
      return false;
    }
    final logoAnterior = fiscalProfile?.logoUrl.trim() ?? '';

    try {
      final raw = await _client.rpc(
        'actualizar_configuracion_negocio_v1',
        params: {'p_datos': datos},
      );

      if (raw is! Map) {
        throw StateError('La configuración devolvió una respuesta inválida.');
      }
      if (_client.auth.currentUser?.id != authUserId) {
        throw StateError('La sesión cambió durante la actualización.');
      }

      final nuevaConfiguracion = Map<String, dynamic>.from(raw);
      _setActiveConfiguration(nuevaConfiguracion, authUserId: authUserId);
      final updatedProfile = fiscalProfile;
      if (updatedProfile == null || !updatedProfile.key.isValid) {
        throw StateError(
          'La configuración actualizada no contiene un perfil válido.',
        );
      }

      final logoNuevo = updatedProfile.logoUrl.trim();

      // La referencia nueva ya fue confirmada por PostgreSQL. Recién ahora es
      // seguro limpiar el logo previo. URLs externas/ajenas se ignoran.
      if (logoAnterior.isNotEmpty && logoAnterior != logoNuevo) {
        await eliminarLogoPropioPorUrl(logoAnterior);
      }

      return true;
    } catch (e, st) {
      debugPrint('Error actualizando configuración del negocio: $e');
      debugPrintStack(stackTrace: st);
      return false;
    }
  }

  /// Sube el logo bajo `<organization_id>/logos/...`. Las policies de Storage
  /// vuelven a comprobar el UUID contra el tenant de auth.uid().
  static Future<String?> subirLogo(
    Uint8List imageBytes,
    String fileExtension,
  ) async {
    try {
      final extension = _normalizarExtension(fileExtension);
      final contentType = _contentTypePara(extension);
      final organizationSegment = _storageOrganizationSegment();

      final fileName =
          '$organizationSegment/logos/logo_${DateTime.now().millisecondsSinceEpoch}.$extension';

      await _client.storage
          .from(_bucketLogos)
          .uploadBinary(
            fileName,
            imageBytes,
            fileOptions: FileOptions(
              contentType: contentType,
              upsert: false,
              cacheControl: '3600',
            ),
          );

      return _client.storage.from(_bucketLogos).getPublicUrl(fileName);
    } catch (e, st) {
      debugPrint('Error subiendo logo a Supabase Storage: $e');
      debugPrintStack(stackTrace: st);
      return null;
    }
  }

  /// Elimina únicamente logos generados para el tenant activo.
  static Future<bool> eliminarLogoPropioPorUrl(String? publicUrl) async {
    final path = _extraerRutaLogoPropio(publicUrl);
    if (path == null) return false;

    try {
      await _client.storage.from(_bucketLogos).remove([path]);
      return true;
    } catch (e, st) {
      debugPrint('Error limpiando logo obsoleto de Storage: $e');
      debugPrintStack(stackTrace: st);
      return false;
    }
  }

  static void _setActiveConfiguration(
    Map<String, dynamic> configuration, {
    required String authUserId,
  }) {
    if (authUserId.isEmpty || _client.auth.currentUser?.id != authUserId) {
      throw StateError('La sesión cambió antes de activar la configuración.');
    }
    final organizationId =
        configuration['organization_id']?.toString().trim() ?? '';
    if (!_isUuid(organizationId)) {
      throw const FormatException(
        'La configuración del negocio no contiene un organization_id válido.',
      );
    }

    final loadedProfile = BusinessFiscalProfileMapper.fromLegacy(configuration);
    if (loadedProfile == null || !loadedProfile.key.isValid) {
      throw const FormatException(
        'La configuración no contiene un perfil fiscal válido.',
      );
    }
    negocioData = configuration;
    _activeProfileKey = loadedProfile.key.normalized();
    _activeOrganizationId = organizationId.toLowerCase();
    _activeAuthUserId = authUserId;
  }

  static String? _extraerRutaLogoPropio(String? publicUrl) {
    final raw = publicUrl?.trim() ?? '';
    if (raw.isEmpty) return null;

    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;

    final marker = '/storage/v1/object/public/$_bucketLogos/';
    final markerIndex = uri.path.indexOf(marker);
    if (markerIndex < 0) return null;

    final encodedPath = uri.path.substring(markerIndex + marker.length);
    if (encodedPath.isEmpty) return null;

    final path = Uri.decodeFull(encodedPath);
    final allowedPrefix = '${_storageOrganizationSegment()}/logos/';
    if (!path.startsWith(allowedPrefix) || path.contains('..')) return null;

    return path;
  }

  static String _storageOrganizationSegment() {
    final value = _activeOrganizationId.trim().toLowerCase();
    if (!_isUuid(value)) {
      throw StateError(
        'Carga primero la configuración del tenant antes de usar Storage.',
      );
    }
    return value;
  }

  static bool _isUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  static String _normalizarExtension(String extension) {
    final value = extension.trim().toLowerCase().replaceFirst('.', '');

    switch (value) {
      case 'jpeg':
      case 'jpg':
        return 'jpg';
      case 'webp':
        return 'webp';
      case 'png':
      default:
        return 'png';
    }
  }

  static String _contentTypePara(String extension) {
    switch (extension) {
      case 'jpg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'png':
      default:
        return 'image/png';
    }
  }
}
