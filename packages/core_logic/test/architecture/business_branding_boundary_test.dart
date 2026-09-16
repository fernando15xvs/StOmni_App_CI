import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe $path');
  return file.readAsStringSync();
}

void main() {
  test('branding compartido es tenant-aware y no duplica configuración', () {
    final domain = _read('lib/business/domain/business_branding.dart');
    final mapper = _read('lib/business/data/business_branding_mapper.dart');
    final gateway = _read(
      'lib/business/data/supabase_business_branding_gateway.dart',
    );
    final providers = _read(
      'lib/business/providers/business_branding_providers.dart',
    );

    expect(domain, isNot(contains('package:flutter/')));
    expect(domain, isNot(contains('Supabase')));
    expect(mapper, contains("row['organization_id']"));
    expect(mapper, contains("row['nombre_comercial']"));
    expect(mapper, contains("row['logo_url']"));
    expect(gateway, contains("rpc('get_current_business_configuration_v1')"));
    expect(gateway, isNot(contains(".from('configuracion_negocio')")));
    expect(gateway, isNot(contains('p_organization_id')));
    expect(gateway, contains('business_branding_v1:\$cacheNamespace:\$user'));
    expect(gateway, contains('_checkUser(user)'));
    expect(
      providers,
      matches(
        RegExp(
          r'FutureProvider\.autoDispose\s*\.family<BusinessBranding,\s*bool>',
        ),
      ),
    );
  });

  test('mobile Web, desktop y documentos consumen la misma identidad', () {
    final mobile = _read('../mobile_app/lib/home/widgets/dashboard_tab.dart');
    final desktop = _read(
      '../desktop_app/lib/features/home/desktop_home_shell.dart',
    );
    final configuration = _read(
      '../mobile_app/lib/features/configuracion/pages/configuracion_negocio_page.dart',
    );
    final quotation = _read('lib/pdf/cotizacion_pdf_renderer.dart');
    final ticket = _read('lib/pdf/venta_ticket_pdf_renderer.dart');

    for (final source in [mobile, desktop]) {
      expect(source, contains('businessBrandingProvider('));
      expect(source, contains('effectiveDisplayName'));
      expect(source, contains('Image.network('));
    }
    expect(configuration, contains('LayoutBuilder('));
    expect(configuration, contains('BoxConstraints(maxWidth: 840)'));
    expect(configuration, contains('businessBrandingProvider(false)'));
    for (final source in [quotation, ticket]) {
      expect(source, contains('fiscalProfile?.tradeName'));
      expect(source, contains('legalName != displayName'));
    }
  });

  test('snapshot fiscal visual se limpia en fronteras de sesión', () {
    final service = _read('lib/services/configuracion_service.dart');
    final auth = _read('lib/auth/controllers/auth_controller.dart');
    final loader = _read(
      '../mobile_app/lib/platform/documents/pdf_branding_loader.dart',
    );

    expect(service, contains('static String _activeAuthUserId'));
    expect(service, contains('clearActiveConfiguration()'));
    expect(service, contains('currentUserId != _activeAuthUserId'));
    expect(auth, contains('ConfiguracionService.clearActiveConfiguration()'));
    expect(loader, contains('BusinessBranding.parseLogoUri'));
    expect(loader, contains("startsWith('image/')"));
    expect(loader, contains('_maxLogoBytes'));
  });
}
