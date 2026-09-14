import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/facturacion/pages/documentos_electronicos_page.dart',
    ).readAsStringSync();
  });

  test('documentos electronicos mapea errores antes de mostrarlos', () {
    expect(source, contains('ErrorMapper.map(error)'));
    expect(source, isNot(contains('reiniciar ? error.toString() : null')));
    expect(source, isNot(contains('Text(error.toString())')));
  });

  test('error inicial conserva una ruta de reintento', () {
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _cargar'));
  });
}
