import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('metadata del paquete conserva la identidad móvil de StOmni', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(
      pubspec,
      contains(
        'description: "StOmni Mobile - cliente Android/iOS para inventario, ventas y operaciones."',
      ),
    );
    expect(pubspec, isNot(contains('description: "A new Flutter project."')));
  });
}
