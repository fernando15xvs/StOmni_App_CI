import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quotation list separates load failure from empty state', () {
    final source = File(
      'lib/features/Cotizar/pages/lista_cotizaciones_page.dart',
    ).readAsStringSync();

    expect(source, contains("import 'package:core_logic/core_logic.dart';"));
    expect(source, contains('String? _errorCarga;'));
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, contains(': _errorCarga != null'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains("'No hay cotizaciones registradas'"));
    expect(
      source,
      isNot(contains("e.toString().replaceFirst('Exception: ', '')")),
    );
  });

  test('empty quotation cart remains a user-facing business validation', () {
    final source = File(
      'lib/features/Cotizar/pages/lista_cotizaciones_page.dart',
    ).readAsStringSync();

    expect(source, contains('throw const UserFacingException('));
    expect(source, contains('La cotización no contiene productos'));
    expect(source, contains('content: Text(ErrorMapper.map(e))'));
  });
}
