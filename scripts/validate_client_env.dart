import 'dart:io';

const allowedClientKeys = <String>{
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
};

void main() {
  final file = File('.env');
  if (!file.existsSync()) {
    stdout.writeln('Client env guard: .env no existe; se usará dart-define.');
    return;
  }

  final violations = <String>[];
  final seen = <String>{};
  final lines = file.readAsLinesSync();

  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    if (line.startsWith('export ')) {
      line = line.substring('export '.length).trimLeft();
    }

    final separator = line.indexOf('=');
    if (separator <= 0) {
      violations.add('línea ${index + 1}: formato KEY=VALUE inválido');
      continue;
    }

    final key = line.substring(0, separator).trim();
    if (key.isEmpty) {
      violations.add('línea ${index + 1}: nombre de variable vacío');
      continue;
    }

    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      violations.add('línea ${index + 1}: nombre de variable inválido');
      continue;
    }

    if (!seen.add(key)) {
      violations.add('$key está definido más de una vez');
      continue;
    }

    if (!allowedClientKeys.contains(key)) {
      violations.add(
        '$key no puede empaquetarse en el cliente. '
        'Muévelo a Supabase Secrets/Edge Functions o al backend correspondiente.',
      );
    }
  }

  if (violations.isNotEmpty) {
    stderr.writeln('Client env guard bloqueó el build:');
    for (final violation in violations) {
      stderr.writeln('- $violation');
    }
    stderr.writeln(
      'El asset .env es legible desde la aplicación compilada. '
      'Solo se permiten variables públicas del cliente.',
    );
    exitCode = 2;
    return;
  }

  stdout.writeln(
    'Client env guard: configuración válida. '
    'Variables permitidas: ${allowedClientKeys.join(', ')}.',
  );
}
