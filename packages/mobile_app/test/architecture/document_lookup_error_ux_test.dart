import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/core/widgets/document_form_kit.dart').readAsStringSync();
  });

  test('lookup DNI/RUC no expone e.toString al usuario', () {
    expect(source, contains('ErrorMapper.map(e)'));
    expect(source, isNot(contains(r"Text('Error: ${e.toString()}')")));
  });

  test('errores de dominio conservan su mensaje tipado', () {
    expect(source, contains('on DocumentLookupException catch (e)'));
    expect(source, contains('content: Text(e.message)'));
  });

  test('Edge get-persona exige empleado activo antes de usar service role', () {
    final edge = repositoryFile(
      'supabase/functions/get-persona/index.ts',
    ).readAsStringSync();

    expect(edge, contains("from '../_shared/auth_guard.ts'"));
    expect(edge, contains('const context = await requireEmployee(req)'));
    expect(edge, contains('const supabaseAdmin = context.admin'));
    expect(edge, contains('error instanceof AuthGuardError'));
    expect(edge, isNot(contains("import { createClient }")));
    expect(edge, isNot(contains("Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')")));
  });
}
