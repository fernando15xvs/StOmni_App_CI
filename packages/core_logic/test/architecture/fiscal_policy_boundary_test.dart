import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ventas delega reglas locales y nunca importa una política de país', () {
    for (final layer in ['domain', 'application', 'usecases']) {
      for (final entity in Directory('lib/features/ventas/$layer').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        expect(source, isNot(contains('PeruSunatFiscalPolicy')), reason: entity.path);
        expect(source, isNot(contains("'factura'")), reason: entity.path);
        expect(source, isNot(contains("'boleta'")), reason: entity.path);
        expect(source, isNot(contains('700.00')), reason: entity.path);
      }
    }
    final composition = File('lib/features/ventas/providers/venta_application_providers.dart').readAsStringSync();
    expect(composition, contains('fiscalPolicyProvider'));
    expect(composition, contains('PeruSunatFiscalPolicy()'));
  });
}
