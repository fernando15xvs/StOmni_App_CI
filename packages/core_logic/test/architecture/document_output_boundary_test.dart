import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core no contiene destinos ni plugins de documentos', () {
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final plugin in ['printing', 'file_picker', 'share_plus', 'path_provider']) {
        expect(source, isNot(contains('package:$plugin/')), reason: file.path);
      }
    }
    final loader = File('lib/pdf/pdf_asset_loader.dart').readAsStringSync();
    expect(loader, isNot(contains('assets/')));
    expect(loader, isNot(contains('http.get')));
    expect(loader, contains('fromBytes(Uint8List? bytes)'));
  });
  test('renderizadores reciben marca y no leen configuración global', () {
    for (final path in ['lib/pdf/cotizacion_pdf_renderer.dart',
      'lib/pdf/venta_ticket_pdf_renderer.dart',
      'lib/features/balance/services/caja_cierre_pdf_renderer.dart']) {
      final source = File(path).readAsStringSync();
      expect(source, contains('PdfBranding? branding'));
      expect(source, isNot(contains('ConfiguracionService')));
      expect(source, isNot(contains('core_logic/core_logic.dart')));
    }
  });
}
