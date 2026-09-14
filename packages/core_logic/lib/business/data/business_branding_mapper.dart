import '../domain/business_branding.dart';

class BusinessBrandingMapper {
  const BusinessBrandingMapper._();

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static BusinessBranding decode(Map<String, dynamic> row) {
    final organizationId = row['organization_id']?.toString().trim() ?? '';
    if (!_uuid.hasMatch(organizationId)) {
      throw const FormatException('Branding empresarial sin tenant válido.');
    }

    final legalName = row['razon_social']?.toString().trim() ?? '';
    final commercialName = row['nombre_comercial']?.toString().trim() ?? '';
    final rawLogoUrl = row['logo_url']?.toString().trim() ?? '';

    return BusinessBranding(
      organizationId: organizationId.toLowerCase(),
      displayName: commercialName.isEmpty ? legalName : commercialName,
      legalName: legalName,
      logoUrl: BusinessBranding.parseLogoUri(rawLogoUrl)?.toString() ?? '',
    );
  }

  static Map<String, dynamic> encode(BusinessBranding branding) => {
    'organization_id': branding.organizationId,
    'nombre_comercial': branding.displayName,
    'razon_social': branding.legalName,
    'logo_url': branding.logoUrl,
  };
}
