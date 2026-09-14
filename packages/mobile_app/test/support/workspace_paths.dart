import 'dart:io';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;

  while (true) {
    final workspace = File(
      '${current.path}${Platform.pathSeparator}pubspec.yaml',
    );
    final mobile = Directory(
      '${current.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}mobile_app',
    );
    final core = Directory(
      '${current.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}core_logic',
    );

    if (workspace.existsSync() && mobile.existsSync() && core.existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'No se pudo localizar la raíz del workspace desde '
        '${Directory.current.path}.',
      );
    }
    current = parent;
  }
}

final Directory _repositoryRoot = _findRepositoryRoot();

String _repositoryPath(String relativePath) {
  return '${_repositoryRoot.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}';
}

File repositoryFile(String relativePath) => File(_repositoryPath(relativePath));

File coreFile(String relativePath) =>
    repositoryFile('packages/core_logic/$relativePath');
