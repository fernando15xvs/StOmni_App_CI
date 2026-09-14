import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quotation detail separates load errors and maps mutations', () {
    final source = File(
      'lib/features/Cotizar/pages/ver_cotizacion_page.dart',
    ).readAsStringSync();

    expect(source, contains("import 'package:core_logic/core_logic.dart';"));
    expect(source, contains('String? _errorCarga;'));
    expect(source, contains('_errorCarga = ErrorMapper.map(e);'));
    expect(source, contains('content: Text(ErrorMapper.map(e))'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, isNot(contains("'Error al cargar datos: \$e'")));
    expect(
      source,
      isNot(contains("e.toString().replaceFirst('Exception: ', '')")),
    );
  });
}
