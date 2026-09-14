import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/empleados/pages/ver_pago_empleado_page.dart',
    ).readAsStringSync();
  });

  test('detalle de pago de empleado no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r'Text("Error: $e")')));
    expect(source, isNot(contains(r"Text('Error: $e')")));
  });

  test('error de carga ofrece recuperación explícita', () {
    expect(source, contains('String? _errorCarga'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _cargarDatos'));
  });
}
