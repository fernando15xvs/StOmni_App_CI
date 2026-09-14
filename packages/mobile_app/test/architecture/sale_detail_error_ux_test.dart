import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/ventas/pages/ver_venta_page.dart',
    ).readAsStringSync();
  });

  test('detalle de venta no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r"Text('Error al cargar datos: $e')")));
    expect(source, isNot(contains(r"Text('Error: $e')")));
    expect(source, isNot(contains(r'Text("Error: $e")')));
    expect(source, isNot(contains(r"Text('No se pudo actualizar: $e')")));
    expect(source, isNot(contains(r"Text('Error de facturación: $e')")));
    expect(
      source,
      isNot(contains(r"Text('No se pudo reconciliar el comprobante: $e')")),
    );
    expect(
      source,
      isNot(contains(r"Text('No se pudo forzar el reintento: $e')")),
    );
  });

  test('fallo inicial de carga ofrece reintento', () {
    expect(source, contains('String? _errorCarga'));
    expect(source, contains("_errorCarga = ErrorMapper.map(e)"));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(source, contains('onPressed: _cargarDatos'));
  });

  test('reconciliacion libera bloqueo antes de refrescar comprobante', () {
    final releaseIndex = source.indexOf(
      'setState(() => _procesandoComprobante = false);',
      source.indexOf('Future<void> _reconciliarResultadoInciertoComprobante()'),
    );
    final refreshIndex = source.indexOf(
      'await _refrescarComprobante();',
      source.indexOf('Future<void> _reconciliarResultadoInciertoComprobante()'),
    );

    expect(releaseIndex, greaterThanOrEqualTo(0));
    expect(refreshIndex, greaterThan(releaseIndex));
    expect(source, contains('liberarBloqueoAntesDeRefresh'));
  });
}
