import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

void main() {
  test('core_logic nunca depende de mobile_app', () {
    final coreDir = Directory('../core_logic/lib');
    expect(
      coreDir.existsSync(),
      isTrue,
      reason: 'El test debe ejecutarse desde packages/mobile_app.',
    );

    final violations = <String>[];

    for (final file in _dartFiles(coreDir)) {
      final path = file.path.replaceAll('\\', '/');
      final content = file.readAsStringSync();

      for (final line in content.split('\n')) {
        final trimmed = line.trimLeft();
        final isDependencyDirective =
            trimmed.startsWith('import ') || trimmed.startsWith('export ');
        if (!isDependencyDirective) continue;

        final dependsOnMobile =
            line.contains('package:mobile_app/') ||
            line.contains('package:ferreteria_app/') ||
            line.contains('/mobile_app/lib/');

        if (dependsOnMobile) {
          violations.add('$path -> ${line.trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'La dependencia permitida es mobile_app -> core_logic, nunca al revés.\n'
          '${violations.join('\n')}',
    );
  });

  test('la capa application de core_logic no usa APIs de presentación', () {
    final coreDir = Directory('../core_logic/lib');
    final violations = <String>[];

    const forbiddenTokens = <String>[
      'package:flutter/material.dart',
      'package:flutter/widgets.dart',
      'BuildContext',
      'Navigator.',
      'AlertDialog',
      'ScaffoldMessenger',
      'showDialog(',
    ];

    for (final file in _dartFiles(coreDir)) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.contains('/application/')) continue;

      final content = file.readAsStringSync();
      for (final forbidden in forbiddenTokens) {
        if (content.contains(forbidden)) {
          violations.add('$path -> $forbidden');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Los casos de uso de core_logic deben ser independientes de widgets y navegación.\n'
          '${violations.join('\n')}',
    );
  });
}
