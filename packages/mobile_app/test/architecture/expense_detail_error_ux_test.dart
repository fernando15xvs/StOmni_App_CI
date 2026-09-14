import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/gastos/pages/ver_gasto_page.dart',
    ).readAsStringSync();
  });

  test('detalle de gasto no muestra excepciones técnicas crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r'Text("Error: $e")')));
    expect(source, isNot(contains(r"Text('Error: $e')")));
  });

  test('fallo de carga es recuperable y diferencia error de datos vacíos', () {
    expect(source, contains('String? _errorCarga'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _cargarDatos'));
  });
}
