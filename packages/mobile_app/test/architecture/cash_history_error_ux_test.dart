import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cash history keeps load errors separate from empty history', () {
    final source = File(
      'lib/features/balance/pages/historial_caja_page.dart',
    ).readAsStringSync();

    expect(source, contains("import 'package:core_logic/core_logic.dart';"));
    expect(source, contains('String? _errorCarga;'));
    expect(source, contains('_errorCarga = ErrorMapper.map(e);'));
    expect(source, contains(': _errorCarga != null'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains("'No hay turnos cerrados en este periodo.'"));

    expect(source, isNot(contains("'Error al cargar historial: \$e'")));
    expect(
      source,
      isNot(contains('SnackBar(content: Text(\'Error al cargar historial')),
    );
  });
}
