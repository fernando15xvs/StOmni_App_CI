import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/balance/pages/caja_chica_page.dart',
    ).readAsStringSync();
  });

  test('error de carga no se interpreta como caja cerrada', () {
    expect(source, contains('String? _errorCarga'));
    expect(source, contains('_errorCarga = ErrorMapper.map(e)'));

    final errorState = source.indexOf('else if (_errorCarga != null)');
    final closedState = source.indexOf(
      "else if (_estadoCaja == null || _estadoCaja!['estado'] == 'CERRADA')",
    );

    expect(errorState, greaterThanOrEqualTo(0));
    expect(closedState, greaterThan(errorState));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _cargarEstado'));
  });

  test('acciones de apertura y cierre no exponen excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r"'Error al abrir caja: $e'")));
    expect(source, isNot(contains(r"'Error al cerrar caja: $e'")));
    expect(source, isNot(contains(r"'Error al cargar caja: $e'")));
  });
}
