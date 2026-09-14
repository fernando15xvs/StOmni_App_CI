import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/empleados/pages/historial_pagos_empleado_page.dart',
    ).readAsStringSync();
  });

  test('historial de pagos no expone excepciones técnicas crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r'"Error: $e"')));
  });

  test('historial de pagos permite reintentar la carga', () {
    expect(source, contains('onPressed: _cargarDatos'));
    expect(source, contains("label: const Text('Reintentar')"));
  });
}
