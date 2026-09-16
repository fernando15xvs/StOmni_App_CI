import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/facturacion/pages/ver_nota_credito_page.dart',
    ).readAsStringSync();
  });

  test('detalle de nota no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, contains('ErrorMapper.map(error)'));
    expect(source, isNot(contains('_error = e.toString()')));
    expect(source, isNot(contains(r"Text('No se pudo procesar la nota: $e')")));
    expect(
      source,
      isNot(contains(r"Text('No se pudo reconciliar la nota: $e')")),
    );
  });

  test('error de carga conserva reintento y mensaje de no disponible', () {
    expect(source, contains('String _mensajeCarga(Object error)'));
    expect(source, contains("'La nota de crédito no está disponible.'"));
    expect(source, contains("'REINTENTAR'"));
    expect(source, contains('onPressed: _cargar'));
  });
}
