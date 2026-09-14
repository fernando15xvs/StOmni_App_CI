import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260822052115_expense_mutation_atomicity.sql';

  test('eliminar pago de gasto recalcula saldo dentro de la RPC', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.eliminar_pago_gasto_v1'));
    expect(sql, contains('FOR UPDATE'));
    expect(sql, contains('DELETE FROM public.pagos_gasto'));
    expect(sql, contains('SELECT COALESCE(SUM(pg.monto), 0)'));
    expect(sql, contains('UPDATE public.gastos'));
    expect(sql, contains("WHEN v_nuevo_saldo <= 0.02 THEN 'pagado'"));
    expect(sql, contains('app_empleado_activo()'));
  });

  test('eliminar gasto usa una sola transaccion y cascade de pagos', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.eliminar_gasto_v1'));
    expect(sql, contains('FROM public.gastos AS g'));
    expect(sql, contains('FOR UPDATE'));
    expect(sql, contains('DELETE FROM public.gastos'));
    expect(
      sql,
      contains('Elimina gasto y pagos asociados en una sola transaccion'),
    );
  });

  test('Flutter elimina mediante RPC y no con deletes separados', () {
    final repository = coreFile(
      'lib/features/gastos/data/gastos_repository.dart',
    ).readAsStringSync();

    expect(repository, contains("'eliminar_pago_gasto_v1'"));
    expect(repository, contains("'eliminar_gasto_v1'"));
    expect(repository, isNot(contains(".from('pagos_gasto').delete()")));
    expect(repository, isNot(contains(".from('gastos').delete()")));
  });

  test('rollout no reintroduce roles tecnicos legacy', () {
    final sql = repositoryFile(migrationPath).readAsStringSync().toLowerCase();

    expect(sql, isNot(contains("'vendedor'")));
    expect(sql, isNot(contains("'almacenero'")));
    expect(sql, isNot(contains("'supervisor'")));
    expect(sql, isNot(contains("'administrador'")));
  });
}
