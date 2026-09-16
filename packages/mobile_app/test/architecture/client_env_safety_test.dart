import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  var current = Directory.current.absolute;

  while (true) {
    final workflow = File(
      '${current.path}${Platform.pathSeparator}.github'
      '${Platform.pathSeparator}workflows'
      '${Platform.pathSeparator}flutter_ci.yml',
    );
    final mobilePackage = Directory(
      '${current.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}mobile_app',
    );

    if (workflow.existsSync() && mobilePackage.existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'No se pudo localizar la raíz del repositorio desde '
        '${Directory.current.path}.',
      );
    }
    current = parent;
  }
}

String _repoPath(Directory root, String relativePath) {
  return '${root.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}';
}

void main() {
  final repositoryRoot = _findRepositoryRoot();

  test('mobile no empaqueta .env ni usa dotenv en runtime', () {
    final validator = File(
      _repoPath(repositoryRoot, 'scripts/validate_client_env.dart'),
    ).readAsStringSync();
    final workflow = File(
      _repoPath(repositoryRoot, '.github/workflows/flutter_ci.yml'),
    ).readAsStringSync();
    final bootstrap = File(
      _repoPath(repositoryRoot, 'packages/mobile_app/lib/app/bootstrap.dart'),
    ).readAsStringSync();
    final pubspec = File(
      _repoPath(repositoryRoot, 'packages/mobile_app/pubspec.yaml'),
    ).readAsStringSync();

    // El validador sigue protegiendo archivos .env locales del repositorio,
    // pero el cliente compilado recibe únicamente configuración pública por
    // --dart-define y nunca empaqueta ese archivo como asset.
    expect(validator, contains("'SUPABASE_URL'"));
    expect(validator, contains("'SUPABASE_ANON_KEY'"));
    expect(validator, contains('if (!allowedClientKeys.contains(key))'));
    expect(validator, contains('exitCode = 2;'));
    expect(workflow, contains('dart run scripts/validate_client_env.dart'));

    expect(
      RegExp(r'^\s*-\s*\.env\s*$', multiLine: true).hasMatch(pubspec),
      isFalse,
    );
    expect(pubspec, isNot(contains('flutter_dotenv:')));

    expect(
      bootstrap,
      isNot(contains('package:flutter_dotenv/flutter_dotenv.dart')),
    );
    expect(bootstrap, isNot(contains('dotenv.')));
    expect(bootstrap, contains("String.fromEnvironment('SUPABASE_URL')"));
    expect(bootstrap, contains("String.fromEnvironment('SUPABASE_ANON_KEY')"));
    expect(bootstrap, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
    expect(bootstrap, isNot(contains('SERVICE_ROLE_KEY')));
    expect(bootstrap, isNot(contains('APIS_PERU_TOKEN')));
    expect(bootstrap, isNot(contains('SUNAT_PASSWORD')));
  });

  test('env example contains no private backend secret names', () {
    final example = File(
      _repoPath(repositoryRoot, '.env.example'),
    ).readAsStringSync();

    expect(example, contains('SUPABASE_URL='));
    expect(example, contains('SUPABASE_ANON_KEY='));
    expect(example, isNot(contains('SERVICE_ROLE_KEY=')));
    expect(example, isNot(contains('APIS_PERU_TOKEN=')));
    expect(example, isNot(contains('SUNAT_PASSWORD=')));
  });
}
