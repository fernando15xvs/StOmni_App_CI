import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('Gestión Transporte queda como composición sin Supabase directo', () {
    final file = File(
      'lib/features/facturacion/pages/gestion_transporte_page.dart',
    );
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(file.readAsLinesSync().length, lessThan(120));
    expect(text, isNot(contains('supabase_flutter')));
    expect(text, isNot(contains('Supabase.instance')));
    expect(text, contains('TransportePrivadoTab'));
    expect(text, contains('TransportePublicoTab'));
  });

  test('pestañas de transporte quedan enfocadas en catálogo y presentación', () {
    final limits = {
      'lib/features/facturacion/widgets/gestion_transporte/transporte_privado_tab.dart':
          230,
      'lib/features/facturacion/widgets/gestion_transporte/transporte_publico_tab.dart':
          330,
    };
    for (final entry in limits.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: entry.key);
      expect(
        file.readAsLinesSync().length,
        lessThan(entry.value),
        reason: entry.key,
      );
    }
  });

  test('widgets de Gestión Transporte no acceden directamente a Supabase', () {
    final directory = Directory(
      'lib/features/facturacion/widgets/gestion_transporte',
    );
    expect(directory.existsSync(), isTrue);

    for (final entity in directory.listSync().whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      expect(text, isNot(contains('supabase_flutter')), reason: entity.path);
      expect(text, isNot(contains('Supabase.instance')), reason: entity.path);
      expect(text, isNot(contains(".from('gre_")), reason: entity.path);
    }
  });

  test('PdfGeneratorService queda como fachada sin acceso a datos', () {
    final file = coreFile('lib/services/pdf_generator_service.dart');
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(file.readAsLinesSync().length, lessThan(140));
    expect(text, isNot(contains('supabase_flutter')));
    expect(text, isNot(contains('Supabase.instance')));
    expect(text, isNot(contains(".from('movimientos')")));
    expect(text, contains('VentaTicketPdfRenderer.generar'));
    expect(text, contains('CotizacionPdfRenderer.generar'));
  });

  test('renderizadores PDF no consultan Supabase', () {
    final paths = [
      'lib/pdf/venta_ticket_pdf_renderer.dart',
      'lib/pdf/cotizacion_pdf_renderer.dart',
      'lib/features/balance/services/caja_cierre_pdf_renderer.dart',
    ];

    for (final path in paths) {
      final file = coreFile(path);
      expect(file.existsSync(), isTrue, reason: path);
      final text = file.readAsStringSync();
      expect(text, isNot(contains('supabase_flutter')), reason: path);
      expect(text, isNot(contains('Supabase.instance')), reason: path);
      expect(text, isNot(contains(".from('movimientos')")), reason: path);
      expect(text, isNot(contains(".from('ventas')")), reason: path);
    }
  });

  test('no quedan llamadas al cierre de caja legado en PdfGeneratorService', () {
    final legacyRefs = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where(
          (file) => file
              .readAsStringSync()
              .contains('PdfGeneratorService.imprimirTicketCierre'),
        )
        .map((file) => file.path)
        .toList();
    expect(legacyRefs, isEmpty);
  });

  test('no quedan scripts temporales de refactor en tool', () {
    final directory = Directory('tool');
    expect(directory.existsSync(), isFalse);
  });
}
