import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe $path');
  return file.readAsStringSync();
}

void main() {
  test(
    'el perfil fiscal es neutral y no depende de proveedor, UI o Supabase',
    () {
      final source = _read(
        'lib/features/facturacion/domain/business_fiscal_profile.dart',
      );

      for (final forbidden in <String>[
        'package:flutter/',
        'flutter_riverpod',
        'BuildContext',
        'Supabase',
        'SUNAT',
        'APISPERU',
        "['ruc']",
        "['igv_porcentaje']",
      ]) {
        expect(source, isNot(contains(forbidden)));
      }

      expect(source, contains('class BusinessFiscalProfile'));
      expect(source, contains('class BusinessFiscalProfileKey'));
      expect(source, contains('class FiscalAddress'));
      expect(source, contains('BusinessFiscalProfileKey get key'));
      expect(source, contains('BusinessFiscalProfile copyWith'));
      expect(source, contains('taxIdentifier'));
      expect(source, contains('standardTaxRatePercent'));
    },
  );

  test('las claves fiscales legacy viven en un mapper dedicado', () {
    final source = _read(
      'lib/features/facturacion/application/business_fiscal_profile_mapper.dart',
    );

    expect(source, contains("raw['ruc']"));
    expect(source, contains("raw['razon_social']"));
    expect(source, contains("raw['cod_local']"));
    expect(source, contains('toLegacyEditableFields'));
    expect(source, isNot(contains("fallback: '1'")));
  });

  test(
    'ConfiguracionService resuelve el perfil por tenant y no por configId de UI',
    () {
      final source = _read('lib/services/configuracion_service.dart');

      expect(source, contains('BusinessFiscalProfile? get fiscalProfile'));
      expect(
        source,
        contains('BusinessFiscalProfileKey get activeFiscalProfileKey'),
      );
      expect(
        source,
        contains('selectFiscalProfile(BusinessFiscalProfileKey key)'),
      );
      expect(source, contains("rpc('get_current_business_configuration_v1')"));
      expect(source, contains("configuration['organization_id']"));
      expect(source, contains('actualizarPerfilFiscal('));
      expect(source, isNot(contains(".from('configuracion_negocio')")));
      expect(source, isNot(contains(".eq('id',")));
      expect(source, isNot(contains('static const int _configId = 1')));
      expect(source, isNot(contains('_legacyWritableBusinessId')));
    },
  );

  test(
    'la pantalla de configuración consume el perfil tipado y no el mapa legacy',
    () {
      final source = _read(
        '../mobile_app/lib/features/configuracion/pages/configuracion_negocio_page.dart',
      );

      expect(source, contains('ConfiguracionService.fiscalProfile'));
      expect(source, contains('ConfiguracionService.actualizarPerfilFiscal('));
      expect(source, contains('currentProfile.copyWith('));
      expect(source, isNot(contains('ConfiguracionService.negocioData')));
      expect(
        source,
        isNot(contains('ConfiguracionService.actualizarNegocio({')),
      );
      expect(source, isNot(contains("data['razon_social']")));
    },
  );

  test(
    'documentos existentes consumen perfil fiscal y no identidad sectorial legacy',
    () {
      for (final path in <String>[
        'lib/pdf/cotizacion_pdf_renderer.dart',
        'lib/pdf/venta_ticket_pdf_renderer.dart',
        'lib/features/balance/services/caja_cierre_pdf_renderer.dart',
      ]) {
        final source = _read(path);
        expect(
          source,
          contains('branding?.fiscalProfile'),
          reason: '$path debe recibir BusinessFiscalProfile como dependencia',
        );
        expect(
          source,
          isNot(contains('ConfiguracionService.negocioData')),
          reason: '$path no debe interpretar el mapa fiscal legacy',
        );
        expect(
          source,
          isNot(contains('Mi Ferretería')),
          reason: '$path no debe fijar identidad de un sector comercial',
        );
      }
    },
  );
}
