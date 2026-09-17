import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metadata del paquete conserva la identidad de StOmni', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(
      pubspec,
      contains(
        'description: "StOmni - gestión de inventario, ventas y operaciones."',
      ),
    );
    expect(pubspec, isNot(contains('description: "A new Flutter project."')));
  });
}
