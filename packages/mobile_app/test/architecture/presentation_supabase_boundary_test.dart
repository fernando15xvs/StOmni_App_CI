import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;

  while (true) {
    final mobileApp = Directory(
      '${current.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}mobile_app',
    );

    if (mobileApp.existsSync()) {
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

bool _isPresentationFile(String relativePath) {
  const presentationDirectories = {'pages', 'widgets', 'presentation'};
  return relativePath.split('/').any(presentationDirectories.contains);
}

void main() {
  final repositoryRoot = _findRepositoryRoot();
  final mobileLib = Directory(
    _repositoryPath(repositoryRoot, 'packages/mobile_app/lib'),
  );

  test('pages, widgets y presentation movil no dependen de Supabase directamente', () {
    expect(mobileLib.existsSync(), isTrue);

    // Detectamos dependencias que identifican inequívocamente a Supabase.
    // No se deben bloquear nombres de métodos genéricos como `.from(...)`,
    // `.auth`, `.storage` o `.rpc(...)` sin conocer el tipo del receptor, ya
    // que APIs Dart ajenas a Supabase pueden usar legítimamente esos nombres.
    final forbiddenSupabaseMarkers = <String, RegExp>{
      'import supabase_flutter': RegExp(r'package:supabase_flutter/'),
      'import supabase': RegExp(r'package:supabase/'),
      'Supabase.instance': RegExp(r'\bSupabase\s*\.\s*instance\b'),
      'SupabaseClient': RegExp(r'\bSupabaseClient\b'),
      'supabaseProvider': RegExp(r'\bsupabaseProvider\b'),
      'supabaseClientProvider': RegExp(r'\bsupabaseClientProvider\b'),
      'supabaseServiceProvider': RegExp(r'\bsupabaseServiceProvider\b'),
    };
    final violations = <String>[];

    for (final file in _dartFiles(mobileLib)) {
      final relativePath = _relativePath(mobileLib, file);
      if (!_isPresentationFile(relativePath)) continue;

      final source = _withoutComments(file.readAsStringSync());
      for (final marker in forbiddenSupabaseMarkers.entries) {
        if (marker.value.hasMatch(source)) {
          violations.add('$relativePath -> ${marker.key}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'La capa de presentacion movil debe delegar el acceso a datos en '
          'repositorios, servicios o casos de uso de core_logic.\n'
          '${violations.join('\n')}',
    );
  });
}
