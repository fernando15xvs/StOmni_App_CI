import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260822052056_warehouse_deactivation_integrity.sql';

  test('desactivacion bloquea cualquier stock distinto de cero', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('COUNT(*) FILTER'));
    expect(sql, contains('COALESCE(ia.cantidad, 0) <> 0'));
    expect(sql, contains('BEFORE UPDATE OF activo ON public.almacenes'));
    expect(sql, contains('desactivar_almacen_seguro_v1'));
    expect(sql, contains("LOWER(COALESCE(e.rol, '')) = 'admin'"));
  });

  test('inventario serializa contra desactivacion y rechaza almacen inactivo', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('FOR KEY SHARE'));
    expect(
      sql,
      contains(
        'BEFORE INSERT OR UPDATE OF almacen_id, cantidad ON public.inventario_almacen',
      ),
    );
    expect(
      sql,
      contains('No se puede registrar stock en un almacen inactivo'),
    );
  });

  test('almacenes ya no exponen DELETE fisico a authenticated', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('DROP POLICY IF EXISTS almacenes_admin_delete'));
    expect(
      sql,
      contains('REVOKE DELETE ON TABLE public.almacenes FROM anon, authenticated'),
    );
  });

  test('Flutter usa RPCs seguras y no cambia activo directamente', () {
    final repository = coreFile(
      'lib/features/almacen/data/almacen_admin_repository.dart',
    ).readAsStringSync();

    expect(repository, contains("'desactivar_almacen_seguro_v1'"));
    expect(repository, contains("'reactivar_almacen_seguro_v1'"));
    expect(
      repository,
      isNot(contains("update({'activo': false})")),
    );
    expect(
      repository,
      isNot(contains("update({'activo': true})")),
    );
  });

  test('migracion no introduce roles tecnicos legacy', () {
    final sql = repositoryFile(migrationPath).readAsStringSync().toLowerCase();

    expect(sql, isNot(contains("'vendedor'")));
    expect(sql, isNot(contains("'almacenero'")));
    expect(sql, isNot(contains("'supervisor'")));
    expect(sql, isNot(contains("'administrador'")));
  });
}
