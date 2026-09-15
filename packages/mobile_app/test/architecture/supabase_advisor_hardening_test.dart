import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  const migrationPath =
      'supabase/migration_sources/pre_bootstrap/20260822052106_advisor_safe_hardening.sql';

  late String sql;

  setUpAll(() {
    sql = repositoryFile(migrationPath).readAsStringSync();
  });

  test('helpers mutables fijan search_path y cierran RPC innecesaria', () {
    expect(
      sql,
      contains('ALTER FUNCTION public.set_facturacion_updated_at()'),
    );
    expect(
      sql,
      contains('ALTER FUNCTION public.set_vendedor_observaciones_kardex()'),
    );
    expect(sql, contains('ALTER FUNCTION public.vincular_usuario_empleado()'));
    expect(
      sql,
      contains(
        'ALTER FUNCTION public.increment_stock(bigint, bigint, integer)',
      ),
    );
    expect(sql, contains('SET search_path TO public, pg_catalog'));
    expect(
      sql,
      contains(
        'REVOKE EXECUTE ON FUNCTION public.increment_stock(bigint, bigint, integer)',
      ),
    );
  });

  test('_gre_empleado_activo no pierde el acceso requerido por RLS', () {
    expect(
      sql,
      isNot(
        contains(
          'REVOKE EXECUTE ON FUNCTION public._gre_empleado_activo()',
        ),
      ),
    );
    expect(sql, contains('public.app_empleado_activo()'));
  });

  test('series_comprobantes usa initplan estable para auth.uid', () {
    expect(sql, contains('ALTER POLICY series_select_empleado'));
    expect(sql, contains('e.auth_id = (SELECT auth.uid())'));
    expect(sql, contains('COALESCE(e.activo, false) = true'));
  });

  test('duplicado UNIQUE se retira mediante constraint y no DROP INDEX', () {
    expect(
      sql,
      contains(
        'DROP CONSTRAINT IF EXISTS inventario_almacen_producto_id_almacen_id_key1',
      ),
    );
    expect(sql, isNot(contains('DROP INDEX')));
    expect(
      sql,
      isNot(
        contains(
          'DROP CONSTRAINT IF EXISTS inventario_almacen_producto_id_almacen_id_key;',
        ),
      ),
    );
  });
}
