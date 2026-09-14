import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;
  while (true) {
    final core = Directory(
      '${current.path}${Platform.pathSeparator}packages${Platform.pathSeparator}core_logic',
    );
    if (core.existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('No se pudo localizar la raiz del workspace.');
    }
    current = parent;
  }
}

Iterable<File> _dartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}

String _relative(Directory root, String path) {
  final rootPath = root.absolute.path.replaceAll('\\', '/');
  final normalized = File(path).absolute.path.replaceAll('\\', '/');
  return normalized.startsWith('$rootPath/')
      ? normalized.substring(rootPath.length + 1)
      : normalized;
}

String? _resolveCoreTarget(Directory coreLib, File source, String target) {
  if (target.startsWith('package:core_logic/')) {
    return target.substring('package:core_logic/'.length);
  }
  if (target.contains(':')) return null;
  final base = Uri.directory('${source.parent.absolute.path}${Platform.pathSeparator}');
  final resolved = base.resolve(target).toFilePath();
  return _relative(coreLib, resolved);
}

String? _layerOf(String path) {
  final segments = path.replaceAll('\\', '/').split('/');
  for (final layer in const [
    'domain',
    'application',
    'usecases',
    'data',
    'providers',
    'presentation',
    'services',
    'database',
    'pdf',
  ]) {
    if (segments.contains(layer)) return layer;
  }
  return null;
}

bool _isReusable(String path) {
  final layer = _layerOf(path);
  return layer == 'domain' || layer == 'application' || layer == 'usecases';
}

void main() {
  final repositoryRoot = _findRepositoryRoot();
  final coreLib = Directory(
    '${repositoryRoot.path}${Platform.pathSeparator}packages'
    '${Platform.pathSeparator}core_logic${Platform.pathSeparator}lib',
  );
  final directive = RegExp(
    "^\\s*(?:import|export)\\s+['\"]([^'\"]+)['\"]",
    multiLine: true,
  );

  test('capas reutilizables no dependen de Riverpod', () {
    final violations = <String>[];
    for (final file in _dartFiles(coreLib)) {
      final sourcePath = _relative(coreLib, file.path);
      if (!_isReusable(sourcePath)) continue;
      final text = file.readAsStringSync();
      if (text.contains('package:flutter_riverpod/') ||
          text.contains('package:riverpod/')) {
        violations.add(sourcePath);
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'domain/application/usecases deben ser framework-free.\n'
          '${violations.join('\n')}',
    );
  });

  test('helpers y barrels tampoco introducen frameworks indirectamente', () {
    final graph = <String, List<String>>{};
    final forbidden = RegExp(
      r'^package:(?:flutter|flutter_riverpod|riverpod|supabase_flutter|printing|'
      r'file_picker|share_plus|path_provider|connectivity_plus|image_picker|'
      r'shared_preferences|sqflite)/',
    );
    for (final file in _dartFiles(coreLib)) {
      graph[_relative(coreLib, file.path)] = [
        for (final match in directive.allMatches(file.readAsStringSync()))
          _resolveCoreTarget(coreLib, file, match.group(1)!) ?? match.group(1)!,
      ];
    }
    final violations = <String>[];
    for (final start in graph.keys.where(_isReusable)) {
      final visited = <String>{};
      final pending = [start];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!visited.add(current)) continue;
        if (forbidden.hasMatch(current)) {
          violations.add('$start -> $current');
          break;
        }
        pending.addAll(graph[current] ?? const <String>[]);
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('dependencias internas de core apuntan hacia capas reutilizables', () {
    const forbiddenOuterLayers = {
      'data',
      'providers',
      'presentation',
      'services',
      'database',
      'pdf',
    };
    final violations = <String>[];

    for (final file in _dartFiles(coreLib)) {
      final sourcePath = _relative(coreLib, file.path);
      final sourceLayer = _layerOf(sourcePath);
      if (sourceLayer != 'domain' &&
          sourceLayer != 'application' &&
          sourceLayer != 'usecases') {
        continue;
      }

      final text = file.readAsStringSync();
      for (final match in directive.allMatches(text)) {
        final target = match.group(1)!;
        final resolved = _resolveCoreTarget(coreLib, file, target);
        if (resolved == null) continue;
        if (resolved == 'core_logic.dart') {
          violations.add('$sourcePath -> barrel de infraestructura');
          continue;
        }
        final targetLayer = _layerOf(resolved);

        if (targetLayer != null && forbiddenOuterLayers.contains(targetLayer)) {
          violations.add('$sourcePath -> $resolved [$targetLayer]');
          continue;
        }

        if (sourceLayer == 'domain' &&
            (targetLayer == 'application' || targetLayer == 'usecases')) {
          violations.add('$sourcePath -> $resolved [$targetLayer]');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'La direccion permitida es infraestructura/composicion -> '
          'application/usecases -> domain.\n${violations.join('\n')}',
    );
  });
}
