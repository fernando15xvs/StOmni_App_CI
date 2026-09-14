import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/features/empleados/pages/gestion_empleados_page.dart',
    ).readAsStringSync();
  });

  test('gestión de personal no muestra excepciones técnicas crudas', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r'Text("Error: $e")')));
    expect(source, isNot(contains("e.toString().replaceAll('Exception: ', '')")));
  });

  test('gestión de personal solo reconoce roles técnicos vigentes', () {
    expect(source, contains("rolActual == 'admin' ? 'admin' : 'operador'"));
    expect(source, isNot(contains("== 'administrador'")));
    expect(source, isNot(contains("value: 'vendedor'")));
    expect(source, isNot(contains("value: 'almacenero'")));
  });

  test('create_employee crea Auth y ficha nueva ya vinculada con payload cerrado', () {
    final edge = repositoryFile(
      'supabase/functions/create_employee/index.ts',
    ).readAsStringSync();

    final createAuth = edge.indexOf('auth.admin.createUser');
    final insertEmployee = edge.indexOf('...newEmployeePayload!');

    expect(edge, contains("requireEmployee(req, ['admin'])"));
    expect(edge, contains("role === 'admin' || role === 'operador'"));
    expect(edge, contains('newEmployeePayload = {'));
    expect(edge, contains('auth_id: newAuthId'));
    expect(edge, contains('creado_por: context.user.id'));
    expect(edge, isNot(contains('const payload = { ...(empleadoData')));
    expect(edge, isNot(contains('.isEmpty')));
    expect(createAuth, greaterThanOrEqualTo(0));
    expect(insertEmployee, greaterThan(createAuth));
  });

  test('create_employee conserva reintento seguro para ficha existente', () {
    final edge = repositoryFile(
      'supabase/functions/create_employee/index.ts',
    ).readAsStringSync();

    expect(edge, contains('const linkExisting = empleadoData == null'));
    expect(edge, contains("targetQuery.eq('id', empleadoId)"));
    expect(edge, contains("targetQuery.eq('email', email)"));
    expect(edge, contains('target.activo !== true'));
    expect(edge, contains(".is('auth_id', null)"));
    expect(edge, contains('Acceso vinculado exitosamente'));
  });

  test('create_employee compensa Auth solo tras verificar fallo de vínculo', () {
    final edge = repositoryFile(
      'supabase/functions/create_employee/index.ts',
    ).readAsStringSync();

    expect(edge, contains("String(verified?.auth_id ?? '') === newAuthId"));
    expect(edge, contains('deleteAuthBestEffort(context.admin, newAuthId)'));
    expect(edge, contains('if (!verifyError)'));
  });
}
