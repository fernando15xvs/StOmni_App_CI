import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/facturacion/pages/ver_guia_remision_page.dart',
    ).readAsStringSync();
  });

  test('detalle GRE no expone excepciones crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, contains('ErrorMapper.map(error)'));
    expect(source, isNot(contains('_error = e.toString()')));
    expect(
      source,
      isNot(contains(r"Text('No se pudo reconciliar la guía: $e')")),
    );
    expect(source, isNot(contains(r"Text('Error al eliminar: $e')")));
  });

  test('mantiene correccion accionable para traslado vencido', () {
    expect(source, contains('e is FacturacionServiceException'));
    expect(source, contains('e.message.trim()'));
    expect(source, contains('_esErrorTrasladoVencido(mensajeDominio)'));
    expect(
      source,
      contains("title: const Text('Actualiza el inicio del traslado')"),
    );
    expect(source, contains("'CORREGIR GUÍA'"));
  });

  test('error de carga sigue siendo recuperable', () {
    expect(source, contains('String _mensajeCarga(Object error)'));
    expect(source, contains("'La guía no está disponible.'"));
    expect(source, contains("'REINTENTAR'"));
    expect(source, contains('onPressed: _cargar'));
  });
}
