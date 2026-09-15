import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

File workspaceFile(String relativePath) => File('../../$relativePath');

void main() {
  test('migración GRE persiste cantidad_bultos y expone RPC v4', () {
    final migration = workspaceFile(
      'supabase/migration_sources/pre_bootstrap/20260820002405_gre_cantidad_bultos.sql',
    ).readAsStringSync();

    expect(migration, contains('cantidad_bultos integer'));
    expect(migration, contains('guardar_guia_remision_v4'));
    expect(migration, contains('p_cantidad_bultos integer'));
    expect(migration, contains('cantidad_bultos = p_cantidad_bultos'));
  });

  test('Edge GRE mapea cantidad_bultos al payload numBultos', () {
    final common = workspaceFile(
      'supabase/functions/_shared/guia_remision_common.ts',
    ).readAsStringSync();

    expect(common, contains('guia.cantidad_bultos'));
    expect(common, contains('envio.numBultos = cantidadBultos'));
  });

  test('Flutter guarda mediante la RPC GRE v4', () {
    final repository = File(
      'lib/features/facturacion/data/guias_remision_repository.dart',
    ).readAsStringSync();

    expect(repository, contains("'guardar_guia_remision_v4'"));
    expect(repository, contains("'p_cantidad_bultos': cantidadBultos"));
  });
}
