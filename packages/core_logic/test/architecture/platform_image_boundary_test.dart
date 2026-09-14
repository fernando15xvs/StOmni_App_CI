import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe $path');
  return file.readAsStringSync();
}

void main() {
  test('el contrato de selección de imágenes es puro y reutilizable', () {
    final source = _read('lib/platform/image_selection.dart');

    for (final forbidden in <String>[
      'package:flutter/',
      'image_picker',
      'image_cropper',
      'BuildContext',
      'XFile',
      'CroppedFile',
      'ImageSource',
    ]) {
      expect(
        source,
        isNot(contains(forbidden)),
        reason: 'El contrato de plataforma no debe depender de $forbidden',
      );
    }

    expect(source, contains('abstract interface class ImageSelectionPort'));
    expect(source, contains('class ImageSelectionRequest'));
    expect(source, contains('class SelectedImageData'));
    expect(source, contains('enum ImageSelectionSource'));
  });

  test('los plugins de imágenes quedan encapsulados en el adaptador móvil', () {
    final source = _read(
      '../mobile_app/lib/platform/mobile_image_selection_adapter.dart',
    );

    expect(source, contains('implements ImageSelectionPort'));
    expect(source, contains('package:image_picker/image_picker.dart'));
    expect(source, contains('package:image_cropper/image_cropper.dart'));
    expect(source, contains('ImageSource.camera'));
    expect(source, contains('ImageSource.gallery'));
  });

  test('el composition root registra el adaptador móvil', () {
    final source = _read('../mobile_app/lib/app/app_dependencies.dart');

    expect(
      source,
      contains('ImageSelectionService.configure(MobileImageSelectionAdapter())'),
    );
  });

  test('configuración selecciona logos sin importar plugins de plataforma', () {
    final source = _read(
      '../mobile_app/lib/features/configuracion/pages/configuracion_negocio_page.dart',
    );

    expect(source, contains('ImageSelectionService.select('));
    expect(source, contains('ImageSelectionSource.gallery'));
    expect(source, isNot(contains('package:image_picker/')));
    expect(source, isNot(contains('ImagePicker')));
    expect(source, isNot(contains('XFile')));
    expect(source, isNot(contains('ImageSource.')));
  });

  test('producto selecciona y recorta fotos mediante el puerto', () {
    final source = _read(
      '../mobile_app/lib/features/almacen/pages/nuevo_producto_page.dart',
    );

    expect(source, contains('ImageSelectionService.select('));
    expect(source, contains('ImageSelectionSource.camera'));
    expect(source, contains('ImageSelectionSource.gallery'));
    expect(source, contains('crop: true'));
    expect(source, isNot(contains('package:image_picker/')));
    expect(source, isNot(contains('package:image_cropper/')));
    expect(source, isNot(contains('ImagePicker')));
    expect(source, isNot(contains('ImageCropper')));
    expect(source, isNot(contains('XFile')));
    expect(source, isNot(contains('ImageSource.')));
  });
}
