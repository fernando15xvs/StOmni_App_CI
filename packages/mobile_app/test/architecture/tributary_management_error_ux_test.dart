import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/facturacion/pages/gestion_tributaria_page.dart',
    ).readAsStringSync();
  });

  test('gestion tributaria no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r"Text('Error: $e')")));
    expect(source, isNot(contains(r"Text('No se pudo cargar: $e')")));
  });

  test('fallo de carga tributaria ofrece recuperación explícita', () {
    expect(source, contains('String? _errorCarga'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _reintentarCarga'));
  });
}
