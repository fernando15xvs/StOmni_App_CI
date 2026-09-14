import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('domain y application no dependen de APIs de presentación', () {
    final features = Directory('lib/features');
    expect(features.existsSync(), isTrue);

    const forbiddenMarkers = <String>[
      "package:flutter/material.dart",
      "package:flutter/cupertino.dart",
      "package:flutter/widgets.dart",
      'BuildContext',
      'showDialog<',
      'showDialog(',
      'Navigator.',
      'Navigator.of(',
      'ScaffoldMessenger',
      'SnackBar(',
      'AlertDialog(',
      'MaterialApp(',
      'CupertinoApp(',
      'package:mobile_app/',
      'package:desktop_app/',
    ];

    final violations = <String>[];

    for (final feature in features.listSync()) {
      if (feature is! Directory) continue;

      for (final layer in const ['domain', 'application', 'usecases']) {
        final directory = Directory('${feature.path}/$layer');
        if (!directory.existsSync()) continue;

        for (final entity in directory.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final source = entity.readAsStringSync();

          for (final marker in forbiddenMarkers) {
            if (source.contains(marker)) {
              violations.add(
                '${entity.path.replaceAll('\\', '/')} contiene "$marker"',
              );
            }
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'La lógica reutilizable no puede depender de una interfaz concreta. '
          'Mueve presentación y APIs de plataforma a mobile_app o desktop_app.\n'
          '${violations.join('\n')}',
    );
  });

  test('core_logic no contiene el adaptador visual de permisos push', () {
    expect(
      File('lib/services/notification_permission_service.dart').existsSync(),
      isFalse,
    );
  });

  test('LocalDbService no depende de Material para registrar errores locales', () {
    final source = File(
      'lib/features/almacen/data/local_db_service.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('package:flutter/material.dart')));
    expect(source, isNot(contains('debugPrint(')));
  });
}
