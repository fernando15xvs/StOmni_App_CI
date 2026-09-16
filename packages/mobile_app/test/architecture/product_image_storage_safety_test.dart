import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('limpieza de imagen nueva exige comprobar referencias en productos', () {
    final repository = coreFile(
      'lib/features/almacen/data/producto_admin_repository.dart',
    ).readAsStringSync();

    expect(repository, contains('limpiarImagenSiNoReferenciada'));
    expect(repository, contains(".eq('imagen_path', publicUrl)"));
    expect(repository, contains('if (reference != null) return;'));
    expect(repository, contains(".remove([path])"));
  });

  test(
    'imagen anterior solo se limpia después de confirmar el nuevo valor',
    () {
      final repository = coreFile(
        'lib/features/almacen/data/producto_admin_repository.dart',
      ).readAsStringSync();

      expect(repository, contains('limpiarImagenAnteriorSiReemplazada'));
      expect(repository, contains(".select('imagen_path')"));
      expect(repository, contains('if (actual != nueva) return;'));
      expect(repository, contains('await _removeIfUnreferenced(anterior)'));
    },
  );

  test('use case conserva rollback reference-aware ante error incierto', () {
    final useCase = coreFile(
      'lib/features/almacen/application/save_product_use_case.dart',
    ).readAsStringSync();

    expect(useCase, contains('ProductImageUpload? uploadedImage'));
    expect(useCase, contains('obtenerImagenActual(currentId)'));
    expect(useCase, contains('limpiarImagenAnteriorSiReemplazada'));
    expect(useCase, contains('limpiarImagenSiNoReferenciada(uploaded.url)'));
    expect(useCase, isNot(contains("storage.from('imagenes_productos')")));
  });

  test('URLs externas no se convierten en rutas borrables del bucket', () {
    final repository = coreFile(
      'lib/features/almacen/data/producto_admin_repository.dart',
    ).readAsStringSync();

    expect(
      repository,
      contains("const marker = '/storage/v1/object/public/\$_imageBucket/'"),
    );
    expect(repository, contains('if (index < 0) return null;'));
  });
}
