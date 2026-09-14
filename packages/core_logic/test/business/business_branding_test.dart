import 'package:core_logic/business/data/business_branding_mapper.dart';
import 'package:core_logic/business/domain/business_branding.dart';
import 'package:core_logic/business/domain/cached_business_branding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const organizationId = '11111111-1111-4111-8111-111111111111';

  test('mapper usa nombre comercial y tenant devuelto por backend', () {
    final branding = BusinessBrandingMapper.decode({
      'organization_id': organizationId.toUpperCase(),
      'nombre_comercial': 'Tienda Centro',
      'razon_social': 'EMPRESA CENTRO SAC',
      'logo_url': 'https://example.com/logo.png',
    });

    expect(branding.organizationId, organizationId);
    expect(branding.effectiveDisplayName, 'Tienda Centro');
    expect(branding.legalName, 'EMPRESA CENTRO SAC');
    expect(branding.logoUri?.scheme, 'https');
  });

  test('nombre legal y StOmni son fallbacks deterministas', () {
    final legal = BusinessBrandingMapper.decode({
      'organization_id': organizationId,
      'nombre_comercial': '   ',
      'razon_social': 'NEGOCIO LEGAL SAC',
    });
    final empty = BusinessBrandingMapper.decode({
      'organization_id': organizationId,
    });

    expect(legal.effectiveDisplayName, 'NEGOCIO LEGAL SAC');
    expect(empty.effectiveDisplayName, BusinessBranding.fallbackDisplayName);
  });

  test('logo admite HTTPS y loopback local, no esquemas o HTTP remotos', () {
    expect(
      BusinessBranding.parseLogoUri('https://cdn.example.com/logo.webp'),
      isNotNull,
    );
    expect(
      BusinessBranding.parseLogoUri(
        'http://127.0.0.1:54321/storage/v1/object/public/logos/logo.png',
      ),
      isNotNull,
    );
    expect(
      BusinessBranding.parseLogoUri('http://example.com/logo.png'),
      isNull,
    );
    expect(BusinessBranding.parseLogoUri('file:///tmp/logo.png'), isNull);
    expect(BusinessBranding.parseLogoUri('data:image/png;base64,AA=='), isNull);
  });

  test('mapper rechaza branding sin organization_id válido', () {
    expect(
      () => BusinessBrandingMapper.decode({
        'organization_id': 'tenant-controlado-por-ui',
        'nombre_comercial': 'Inválido',
      }),
      throwsFormatException,
    );
  });

  test('snapshot visual expira y tolera sólo sesgo futuro pequeño', () {
    final now = DateTime.utc(2026, 9, 9, 12);
    const branding = BusinessBranding(
      organizationId: organizationId,
      displayName: 'Tienda Centro',
      legalName: 'EMPRESA CENTRO SAC',
    );

    expect(
      CachedBusinessBranding(
        branding: branding,
        cachedAt: now.subtract(const Duration(hours: 23)),
      ).isCurrentAt(now),
      isTrue,
    );
    expect(
      CachedBusinessBranding(
        branding: branding,
        cachedAt: now.subtract(const Duration(hours: 24)),
      ).isCurrentAt(now),
      isFalse,
    );
    expect(
      CachedBusinessBranding(
        branding: branding,
        cachedAt: now.add(const Duration(minutes: 6)),
      ).isCurrentAt(now),
      isFalse,
    );
  });
}
