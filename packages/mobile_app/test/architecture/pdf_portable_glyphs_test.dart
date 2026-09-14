import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String cotizacion;

  setUpAll(() {
    cotizacion = coreFile(
      'lib/pdf/cotizacion_pdf_renderer.dart',
    ).readAsStringSync();
  });

  test('cotización no depende de iconos Material sin fuente PDF', () {
    expect(cotizacion, isNot(contains('IconData(0xe5ca)')));
    expect(cotizacion, isNot(contains('pw.Icon(')));
  });

  test('indicador de calidad usa contenido portable', () {
    final checkStart = cotizacion.indexOf('static pw.Widget _check');
    expect(checkStart, greaterThanOrEqualTo(0));
    final checkSection = cotizacion.substring(checkStart);
    expect(checkSection, contains("'OK'"));
    expect(checkSection, contains('pw.Text('));
  });
}
