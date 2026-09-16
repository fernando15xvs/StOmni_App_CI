import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String page;
  late String repository;

  setUpAll(() {
    page = File(
      'lib/features/deudas/pages/deudas_page.dart',
    ).readAsStringSync();
    repository = coreFile(
      'lib/features/deudas/data/deudas_repository.dart',
    ).readAsStringSync();
  });

  test('cartera distingue error remoto de lista vacia', () {
    expect(page, contains('String? _errorCarga'));
    expect(page, contains("'No se pudo cargar la cartera'"));
    expect(page, contains("label: const Text('Reintentar')"));
    expect(page, contains('onPressed: _cargarTodo'));
    expect(page, contains("'Nadie te debe nada'"));
  });

  test('deudas traduce errores y no muestra excepcion tecnica', () {
    expect(page, contains('_errorCarga = ErrorMapper.map(e)'));
    expect(page, isNot(contains(r"Text('Error: $e')")));
    expect(repository, contains('UserFacingException(ErrorMapper.map(e))'));
  });

  test('TabController se libera al desmontar la pantalla', () {
    expect(page, contains('_tabController.dispose()'));
  });
}
