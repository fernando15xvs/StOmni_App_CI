import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

String read(String path) => repositoryFile(path).readAsStringSync();

void main() {
  test('todas las Edge Functions declaradas mantienen verify_jwt', () {
    final config = read('supabase/config.toml');

    expect(config, isNot(contains('verify_jwt = false')));
    expect(config, contains('[functions.get-persona]'));
    expect(config, contains('[functions.create_employee]'));
    expect(config, contains('[functions.delete_employee]'));
    expect(config, contains('[functions.resolver-resultado-incierto]'));
  });

  test('guard comun solo reconoce admin y operador activos', () {
    final guard = read('supabase/functions/_shared/auth_guard.ts');

    expect(guard, contains("export type AppRole = 'admin' | 'operador'"));
    expect(guard, contains("if (role === 'admin') return 'admin'"));
    expect(guard, contains("if (role === 'operador') return 'operador'"));
    expect(guard, contains('empleado.activo !== true'));
    expect(guard, contains('admin.auth.getUser(token)'));
    expect(guard, isNot(contains("role === 'vendedor'")));
    expect(guard, isNot(contains("role === 'almacenero'")));
  });

  test('endpoints independientes exigen el rol esperado', () {
    final createEmployee = read('supabase/functions/create_employee/index.ts');
    final deleteEmployee = read('supabase/functions/delete_employee/index.ts');
    final persona = read('supabase/functions/get-persona/index.ts');
    final uncertain = read(
      'supabase/functions/resolver-resultado-incierto/index.ts',
    );

    expect(createEmployee, contains("requireEmployee(req, ['admin'])"));
    expect(deleteEmployee, contains("requireEmployee(req, ['admin'])"));
    expect(persona, contains('const context = await requireEmployee(req)'));
    expect(uncertain, contains("requireEmployee(req, ['admin'])"));
  });

  test('operaciones tributarias masivas son solo admin', () {
    final paths = [
      'supabase/functions/reintentar-comprobantes-pendientes/index.ts',
      'supabase/functions/reintentar-notas-credito-pendientes/index.ts',
      'supabase/functions/reintentar-guias-pendientes/index.ts',
      'supabase/functions/ejecutar-resumen-diario/index.ts',
    ];

    for (final path in paths) {
      expect(
        read(path),
        contains("createUserContext(req, ['admin'])"),
        reason: path,
      );
    }
  });

  test('procesos tributarios usan admin como rol por defecto', () {
    final common = read(
      'supabase/functions/_shared/proceso_tributario_common.ts',
    );

    expect(common, contains("allowedRoles: readonly AppRole[] = ['admin']"));
  });
}
