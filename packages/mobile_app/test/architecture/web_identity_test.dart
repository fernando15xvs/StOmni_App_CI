import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String indexHtml;
  late String manifest;
  late String pubspec;

  setUpAll(() {
    indexHtml = File('web/index.html').readAsStringSync();
    manifest = File('web/manifest.json').readAsStringSync();
    pubspec = File('pubspec.yaml').readAsStringSync();
  });

  test('Web no expone el nombre placeholder del proyecto Flutter', () {
    expect(indexHtml, contains('<title>StOmni</title>'));
    expect(indexHtml, contains('apple-mobile-web-app-title" content="StOmni"'));
    expect(indexHtml, isNot(contains('<title>ferreteria_app</title>')));
    expect(indexHtml, isNot(contains('A new Flutter project.')));
  });

  test('PWA usa StOmni como nombre visible', () {
    expect(manifest, contains('"name": "StOmni"'));
    expect(manifest, contains('"short_name": "StOmni"'));
    expect(manifest, isNot(contains('"name": "ferreteria_app"')));
    expect(manifest, isNot(contains('A new Flutter project.')));
  });

  test('metadata del paquete no conserva la descripcion placeholder', () {
    expect(
      pubspec,
      contains(
        'description: "StOmni - gestión de inventario, ventas y operaciones."',
      ),
    );
    expect(pubspec, isNot(contains('description: "A new Flutter project."')));
  });
}
