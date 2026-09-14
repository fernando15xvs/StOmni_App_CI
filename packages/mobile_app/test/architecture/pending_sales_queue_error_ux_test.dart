import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pending sales queue keeps raw diagnostics out of the UI', () {
    final source = File(
      'lib/features/balance/widgets/ventas_pendientes_dialog.dart',
    ).readAsStringSync();

    expect(source, contains("import 'package:core_logic/core_logic.dart';"));
    expect(source, contains('ErrorMapper.map(ultimoError)'));
    expect(source, contains("'Último intento: \$ultimoErrorVisible'"));
    expect(source, isNot(contains("'Último error: \$ultimoError'")));
  });
}
