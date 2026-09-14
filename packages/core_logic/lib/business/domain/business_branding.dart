/// Identidad visual de la organización autenticada.
///
/// El backend deriva [organizationId] desde Auth. El cliente nunca lo usa
/// como selector de tenant; sólo sirve para validar y aislar snapshots.
class BusinessBranding {
  const BusinessBranding({
    required this.organizationId,
    required this.displayName,
    required this.legalName,
    this.logoUrl = '',
  });

  static const fallbackDisplayName = 'StOmni';

  final String organizationId;
  final String displayName;
  final String legalName;
  final String logoUrl;

  String get effectiveDisplayName {
    final commercial = displayName.trim();
    if (commercial.isNotEmpty) return commercial;
    final legal = legalName.trim();
    return legal.isEmpty ? fallbackDisplayName : legal;
  }

  Uri? get logoUri => parseLogoUri(logoUrl);

  /// Acepta HTTPS y HTTP únicamente para desarrollo local/loopback.
  /// Evita que valores `file:`, `data:` o HTTP remoto lleguen a renderizadores.
  static Uri? parseLogoUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme.toLowerCase() == 'https') return uri;
    if (uri.scheme.toLowerCase() != 'http') return null;
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
            host == '127.0.0.1' ||
            host == '::1'
        ? uri
        : null;
  }
}
