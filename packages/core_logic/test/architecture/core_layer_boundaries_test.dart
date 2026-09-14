import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;

  while (true) {
    final coreLogic = Directory(
      '${current.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}core_logic',
    );

    if (coreLogic.existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'No se pudo localizar la raiz del repositorio desde '
        '${Directory.current.path}.',
      );
    }
    current = parent;
  }
}

String _repositoryPath(Directory root, String relativePath) {
  return '${root.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}';
}

Iterable<File> _dartFiles(Directory directory) sync* {
  if (!directory.existsSync()) return;

  for (final entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

String _relativePath(Directory root, File file) {
  final normalizedRoot = root.absolute.path.replaceAll('\\', '/');
  final normalizedFile = file.absolute.path.replaceAll('\\', '/');
  final rootPrefix = '$normalizedRoot/';

  return normalizedFile.startsWith(rootPrefix)
      ? normalizedFile.substring(rootPrefix.length)
      : normalizedFile;
}

String _withoutComments(String source) {
  return source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\r\n]*'), '');
}

Set<String> _clientPackageNames(Directory repositoryRoot) {
  final packagesDirectory = Directory(_repositoryPath(repositoryRoot, 'packages'));
  final clientPackages = <String>{
    // Protege tambien contra nombres usados antes de convertir el proyecto
    // en un workspace, aunque ya no existan como paquetes locales.
    'ferreteria_app',
    'conductor_app',
  };

  for (final entity in packagesDirectory.listSync()) {
    if (entity is! Directory) continue;

    final pubspec = File('${entity.path}${Platform.pathSeparator}pubspec.yaml');
    if (!pubspec.existsSync()) continue;

    final match = RegExp(r'^\s*name\s*:\s*([A-Za-z0-9_-]+)\s*$', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    final packageName = match?.group(1);
    if (packageName != null && packageName != 'core_logic') {
      clientPackages.add(packageName);
    }
  }

  return clientPackages;
}

bool _referencesClientPackage(String target, Set<String> clientPackages) {
  final normalizedTarget = target.replaceAll('\\', '/');

  for (final clientPackage in clientPackages) {
    if (normalizedTarget.startsWith('package:$clientPackage/') ||
        normalizedTarget == 'package:$clientPackage' ||
        normalizedTarget.contains('/packages/$clientPackage/') ||
        normalizedTarget.contains('/$clientPackage/')) {
      return true;
    }
  }

  return false;
}

bool _belongsToReusableLayer(String relativePath) {
  const reusableLayers = {'domain', 'application', 'usecases'};
  return relativePath.split('/').any(reusableLayers.contains);
}

void main() {
  final repositoryRoot = _findRepositoryRoot();
  final coreLib = Directory(_repositoryPath(repositoryRoot, 'packages/core_logic/lib'));

  test('todo core_logic queda libre de UI y plugins exclusivamente móviles', () {
    final forbidden = RegExp(
      r'package:flutter/(?:material|cupertino|widgets)\.dart|'
      r'package:(?:connectivity_plus|image_picker|onesignal_flutter|printing|'
      r'file_picker|share_plus|path_provider)/|'
      r'\b(?:BuildContext|AppLifecycleListener|Navigator|ScaffoldMessenger)\b',
    );
    final violations = [
      for (final file in _dartFiles(coreLib))
        if (forbidden.hasMatch(_withoutComments(file.readAsStringSync())))
          _relativePath(coreLib, file),
    ];
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('core_logic no depende de aplicaciones cliente', () {
    expect(coreLib.existsSync(), isTrue);

    final clientPackages = _clientPackageNames(repositoryRoot);
    final violations = <String>[];
    final directivePattern = RegExp(
      "^\\s*(?:import|export|part)\\s+['\"]([^'\"]+)['\"]",
      multiLine: true,
    );

    for (final file in _dartFiles(coreLib)) {
      final source = _withoutComments(file.readAsStringSync());

      for (final directive in directivePattern.allMatches(source)) {
        final target = directive.group(1)!;
        if (_referencesClientPackage(target, clientPackages)) {
          violations.add('${_relativePath(coreLib, file)} -> $target');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'La dependencia permitida es cliente -> core_logic; '
          'core_logic no puede importar, exportar ni incluir codigo de un cliente.\n'
          '${violations.join('\n')}',
    );
  });

  test('domain, application y usecases no conocen UI, Supabase ni plugins', () {
    expect(coreLib.existsSync(), isTrue);

    final forbiddenUiMarkers = <String, RegExp>{
      'import Flutter UI': RegExp(
        r"package:flutter/(?:material|cupertino|widgets)(?:\.dart|/)|dart:ui",
      ),
      'BuildContext': RegExp(r'\bBuildContext\b'),
      'widget Flutter': RegExp(
        r'\b(?:Widget|StatelessWidget|StatefulWidget|ConsumerWidget|'
        r'HookWidget|InheritedWidget|RenderObjectWidget)\b',
      ),
      'navegacion Flutter': RegExp(r'\bNavigator(?:\.of)?\b'),
      'dialogo Flutter': RegExp(r'\b(?:showDialog|showModalBottomSheet)\b'),
      'feedback Flutter': RegExp(r'\b(?:ScaffoldMessenger|SnackBar|AlertDialog)\b'),
      'app Flutter': RegExp(r'\b(?:MaterialApp|CupertinoApp)\b'),
      'contexto visual': RegExp(r'\b(?:Theme|MediaQuery)\.of\b'),
      'import Supabase': RegExp(r'package:supabase_flutter/'),
      'cliente Supabase': RegExp(r'\b(?:SupabaseClient|Supabase)\b'),
      'import de plugin de plataforma': RegExp(
        r'package:(?:connectivity_plus|file_picker|image_picker|'
        r'onesignal_flutter|path_provider|permission_handler|printing|'
        r'share_plus|shared_preferences|sqflite)/',
      ),
      'lifecycle de aplicacion': RegExp(r'\bAppLifecycleListener\b'),
      'deteccion de conectividad': RegExp(r'\bConnectivity\s*\('),
    };
    final violations = <String>[];

    for (final file in _dartFiles(coreLib)) {
      final relativePath = _relativePath(coreLib, file);
      if (!_belongsToReusableLayer(relativePath)) continue;

      final source = _withoutComments(file.readAsStringSync());
      for (final marker in forbiddenUiMarkers.entries) {
        if (marker.value.hasMatch(source)) {
          violations.add('$relativePath -> ${marker.key}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Las capas domain, application y usecases deben ser reutilizables '
          'por mobile_app y desktop_app, sin UI, Supabase ni plugins de plataforma.\n'
          '${violations.join('\n')}',
    );
  });
}
