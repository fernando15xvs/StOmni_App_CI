import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('business logo cleanup happens only after confirmed config update', () {
    final service = coreFile(
      'lib/services/configuracion_service.dart',
    ).readAsStringSync();

    final captureOld = service.indexOf(
      "final logoAnterior = fiscalProfile?.logoUrl.trim() ?? '';",
    );
    final rpc = service.indexOf("'actualizar_configuracion_negocio_v1'");
    final confirm = service.indexOf('_setActiveConfiguration(nuevaConfiguracion);');
    final cleanup = service.indexOf(
      'await eliminarLogoPropioPorUrl(logoAnterior);',
    );

    expect(captureOld, greaterThanOrEqualTo(0));
    expect(rpc, greaterThan(captureOld));
    expect(confirm, greaterThan(rpc));
    expect(cleanup, greaterThan(confirm));
  });

  test('logo cleanup refuses URLs outside the current tenant UUID prefix', () {
    final service = coreFile(
      'lib/services/configuracion_service.dart',
    ).readAsStringSync();

    expect(
      service,
      contains("final marker = '/storage/v1/object/public/\$_bucketLogos/';"),
    );
    expect(
      service,
      contains(
        "final allowedPrefix = '\${_storageOrganizationSegment()}/logos/';",
      ),
    );
    expect(service, contains("configuration['organization_id']"));
    expect(service, contains("path.contains('..')"));
    expect(service, isNot(contains("'empresa_\$businessSegment/")));
  });

  test('newly uploaded logo is compensated when config is not confirmed', () {
    final page = File(
      'lib/features/configuracion/pages/configuracion_negocio_page.dart',
    ).readAsStringSync();

    expect(page, contains('String? logoSubidoEnEsteIntento;'));
    expect(page, contains('var configuracionConfirmada = false;'));
    expect(page, contains('configuracionConfirmada = true;'));
    expect(
      page,
      contains('if (!configuracionConfirmada && logoSubidoEnEsteIntento != null)'),
    );
    expect(
      page,
      contains('ConfiguracionService.eliminarLogoPropioPorUrl('),
    );
  });
}
