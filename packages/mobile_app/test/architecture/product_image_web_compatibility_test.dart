import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String page;
  late String controller;
  late String repository;
  late String adapter;
  late String webIndex;

  setUpAll(() {
    page = File(
      'lib/features/almacen/pages/nuevo_producto_page.dart',
    ).readAsStringSync();
    controller = File(
      'lib/features/almacen/presentation/controllers/nuevo_producto_controller.dart',
    ).readAsStringSync();
    repository = coreFile(
      'lib/features/almacen/data/producto_admin_repository.dart',
    ).readAsStringSync();
    adapter = File(
      'lib/platform/mobile_image_selection_adapter.dart',
    ).readAsStringSync();
    webIndex = File('web/index.html').readAsStringSync();
  });

  test('flujo de imagen de producto no depende de dart:io', () {
    for (final source in [page, controller, repository]) {
      expect(source, isNot(contains("import 'dart:io';")));
    }
  });

  test('selección y preview usan bytes multiplataforma', () {
    expect(page, contains('ImageSelectionService.select('));
    expect(page, contains('selected.bytes'));
    expect(page, contains('Uint8List? _imagenNuevaBytes'));
    expect(page, contains('Image.memory(_imagenNuevaBytes!'));
    expect(page, isNot(contains('Image.file(')));
    expect(page, contains('ErrorMapper.map(e)'));
    expect(controller, contains('Uint8List? imagenNuevaBytes'));
    expect(repository, contains('subirImagen(Uint8List bytes)'));
  });

  test('cropper queda encapsulado y conserva salida JPEG coherente', () {
    expect(page, isNot(contains('package:image_cropper/')));
    expect(adapter, contains('ImageCropper'));
    expect(adapter, contains('compressFormat: ImageCompressFormat.jpg'));
    expect(webIndex, contains('cropperjs/1.6.2/cropper.css'));
    expect(webIndex, contains('cropperjs/1.6.2/cropper.min.js'));
  });

  test('Storage sube bytes y conserva limpieza reference-aware', () {
    expect(repository, contains('subirImagen(Uint8List bytes)'));
    expect(repository, contains('uploadBinary('));
    expect(repository, contains("contentType: 'image/jpeg'"));
    expect(repository, isNot(contains('.upload(fileName')));
    expect(repository, contains('limpiarImagenSiNoReferenciada'));
    expect(repository, contains('limpiarImagenAnteriorSiReemplazada'));
  });
}
