import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('business config logo flow is web compatible', () {
    final source = File(
      'lib/features/configuracion/pages/configuracion_negocio_page.dart',
    ).readAsStringSync();

    expect(source, contains('Uint8List? _logoNuevoBytes'));
    expect(source, isNot(contains("import 'dart:io';")));
    expect(source, contains('ImageSelectionService.select('));
    expect(source, contains('_logoNuevoBytes = image.bytes'));
    expect(source, isNot(contains('package:image_picker/')));
    expect(source, contains('Image.memory(_logoNuevoBytes!'));
    expect(source, isNot(contains('Image.file(')));
    expect(source, isNot(contains('File? _logoNuevo')));
  });

  test('business config separates load failure and logo upload failure', () {
    final source = File(
      'lib/features/configuracion/pages/configuracion_negocio_page.dart',
    ).readAsStringSync();

    expect(source, contains('String? _errorCarga;'));
    expect(source, contains('_errorCarga = ErrorMapper.map(e)'));
    expect(source, contains("label: const Text('Reintentar')"));
    expect(
      source,
      contains('if (urlPublica == null || urlPublica.trim().isEmpty)'),
    );
    expect(source, contains('throw const UserFacingException('));
    expect(
      source,
      anyOf(
        contains('content: Text(ErrorMapper.map(e))'),
        contains('_mostrarError(ErrorMapper.map(e))'),
      ),
    );
    expect(source, isNot(contains("'Error al guardar: \$e'")));
  });
}
