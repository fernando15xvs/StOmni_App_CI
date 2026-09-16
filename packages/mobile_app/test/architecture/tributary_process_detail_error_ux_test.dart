import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/facturacion/pages/ver_proceso_tributario_page.dart',
    ).readAsStringSync();
  });

  test('detalle de proceso tributario no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, contains('ErrorMapper.map(error)'));
    expect(source, isNot(contains('_error = e.toString()')));
    expect(source, isNot(contains(r"Text('No se pudo reintentar: $e')")));
    expect(
      source,
      isNot(contains(r"Text('No se pudo reconciliar el proceso: $e')")),
    );
  });

  test('error de carga tiene estado recuperable', () {
    expect(source, contains('String _mensajeCarga(Object error)'));
    expect(source, contains("'El proceso tributario no está disponible.'"));
    expect(source, contains("'REINTENTAR'"));
    expect(source, contains('onPressed: _cargar'));
  });

  test('respeta el tema de la aplicacion en vez de fondo claro fijo', () {
    expect(
      source,
      contains('backgroundColor: Theme.of(context).scaffoldBackgroundColor'),
    );
    expect(source, isNot(contains('backgroundColor: const Color(0xFFF3F4F6)')));
  });
}
