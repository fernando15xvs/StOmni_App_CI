import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('NuevaGuiaRemisionPage queda como orquestador y no vuelve a ser monolítica', () {
    final file = File(
      'lib/features/facturacion/pages/nueva_guia_remision_page.dart',
    );
    expect(file.existsSync(), isTrue);

    final text = file.readAsStringSync();
    final lineas = file.readAsLinesSync().length;

    expect(
      lineas,
      lessThan(600),
      reason: 'Nueva GRE debe mantenerse por debajo de 600 líneas.',
    );
    expect(text, isNot(contains('Widget _seccionRuta()')));
    expect(text, isNot(contains('Widget _seccionTransporte()')));
    expect(text, isNot(contains('Widget _seccionProductos()')));
    expect(text, isNot(contains("core/utils/stock_utils.dart")));
    expect(text, isNot(contains('DateFormat(')));
    expect(text, contains('GreSubmissionCoordinator.preparar('));
    expect(text, contains('GreRutaSection('));
    expect(text, contains('GreTransporteSection('));
    expect(text, contains('GreProductosSection('));
  });
}
