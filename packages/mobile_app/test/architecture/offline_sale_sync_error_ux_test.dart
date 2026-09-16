import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offline sale synchronization does not expose raw exceptions', () {
    final source = File(
      'lib/features/balance/utils/balance_service.dart',
    ).readAsStringSync();

    expect(source, contains("import 'package:core_logic/core_logic.dart';"));
    expect(source, contains('content: Text(ErrorMapper.map(syncError))'));
    expect(source, contains('debugPrintStack(stackTrace: st);'));
    expect(
      source,
      isNot(
        contains("content: Text('Error general al sincronizar: \$syncError')"),
      ),
    );
  });
}
