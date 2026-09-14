import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/almacen/pages/almacen_page.dart',
    ).readAsStringSync();
  });

  test('inventario no expone excepciones crudas al usuario', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, contains('ErrorMapper.map(error)'));
    expect(source, isNot(contains(r'Text("Error al exportar: $e")')));
    expect(source, isNot(contains(r'Text("Error al generar PDF: $e")')));
    expect(source, isNot(contains("Center(child: Text('Error: \$err'))")));
    expect(source, isNot(contains(r"content: Text('Error: $e')")));
  });

  test('fallo del listado ofrece recuperacion explicita', () {
    expect(source, contains('Widget _buildLoadError(Object error)'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('productosInactivosFutureProvider'));
    expect(source, contains('almacenNotifierProvider.notifier).recargar()'));
  });
}
