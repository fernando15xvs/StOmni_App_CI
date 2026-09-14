import 'dart:io';

const _usage = '''
Usage:
  dart run scripts/clean_imports.dart --check <path> [<path> ...]
  dart run scripts/clean_imports.dart --write <path> [<path> ...]

Removes repeated, single-line Dart import directives from explicitly supplied
files or directories. --check reports pending changes without modifying files.
''';

enum _Mode { check, write }

void main(List<String> arguments) {
  if (arguments.length == 1 &&
      (arguments.single == '--help' || arguments.single == '-h')) {
    stdout.write(_usage);
    return;
  }

  final parsed = _parseArguments(arguments);
  if (parsed == null) {
    exitCode = 64;
    return;
  }

  final (mode, paths) = parsed;
  final files = _collectDartFiles(paths);
  if (files == null) {
    exitCode = 64;
    return;
  }

  var changedFiles = 0;
  var removedImports = 0;

  for (final file in files) {
    final result = _removeDuplicateImports(file.readAsStringSync());
    if (result.removedImports == 0) {
      continue;
    }

    changedFiles++;
    removedImports += result.removedImports;
    final action = mode == _Mode.write ? 'Fixed' : 'Would fix';
    stdout.writeln(
      '$action ${file.path} (${result.removedImports} duplicate imports)',
    );

    if (mode == _Mode.write) {
      file.writeAsStringSync(result.source);
    }
  }

  final summary = '$changedFiles file(s), $removedImports duplicate import(s)';
  if (mode == _Mode.check && changedFiles > 0) {
    stderr.writeln(
      'Duplicate imports found: $summary. Run with --write to fix them.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    mode == _Mode.write ? 'Completed: $summary.' : 'Check passed: $summary.',
  );
}

(_Mode, List<String>)? _parseArguments(List<String> arguments) {
  _Mode? mode;
  final paths = <String>[];

  for (final argument in arguments) {
    switch (argument) {
      case '--check':
        if (mode != null) {
          stderr.writeln('Specify exactly one of --check or --write.');
          stderr.write(_usage);
          return null;
        }
        mode = _Mode.check;
        break;
      case '--write':
        if (mode != null) {
          stderr.writeln('Specify exactly one of --check or --write.');
          stderr.write(_usage);
          return null;
        }
        mode = _Mode.write;
        break;
      default:
        if (argument.startsWith('-')) {
          stderr.writeln('Unknown option: $argument');
          stderr.write(_usage);
          return null;
        }
        paths.add(argument);
    }
  }

  if (mode == null || paths.isEmpty) {
    stderr.writeln('A mode and at least one explicit path are required.');
    stderr.write(_usage);
    return null;
  }

  return (mode, paths);
}

List<File>? _collectDartFiles(List<String> paths) {
  final filesByPath = <String, File>{};

  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        if (!path.endsWith('.dart')) {
          stderr.writeln('Not a Dart file: $path');
          return null;
        }
        final file = File(path);
        filesByPath[file.absolute.path] = file;
        break;
      case FileSystemEntityType.directory:
        final directory = Directory(path);
        for (final entity
            in directory.listSync(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            filesByPath[entity.absolute.path] = entity;
          }
        }
        break;
      case FileSystemEntityType.notFound:
        stderr.writeln('Path not found: $path');
        return null;
      default:
        stderr.writeln('Unsupported path type: $path');
        return null;
    }
  }

  return filesByPath.values.toList()
    ..sort((first, second) => first.path.compareTo(second.path));
}

_CleanResult _removeDuplicateImports(String source) {
  final lineEnding = source.contains('\r\n') ? '\r\n' : '\n';
  final hasTrailingLineEnding = source.endsWith('\n');
  final lines = source.split(RegExp(r'\r?\n'));
  if (hasTrailingLineEnding) {
    lines.removeLast();
  }

  final seenImports = <String>{};
  final cleanedLines = <String>[];
  var removedImports = 0;

  for (final line in lines) {
    final import = _singleLineImport(line);
    if (import != null && !seenImports.add(import)) {
      removedImports++;
      continue;
    }
    cleanedLines.add(line);
  }

  final cleanedSource = '${cleanedLines.join(lineEnding)}'
      '${hasTrailingLineEnding ? lineEnding : ''}';
  return _CleanResult(cleanedSource, removedImports);
}

String? _singleLineImport(String line) {
  final import = line.trim();
  return RegExp(r'^import\s+.+;\s*$').hasMatch(import) ? import : null;
}

class _CleanResult {
  const _CleanResult(this.source, this.removedImports);

  final String source;
  final int removedImports;
}
