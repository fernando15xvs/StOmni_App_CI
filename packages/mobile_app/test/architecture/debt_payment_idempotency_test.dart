import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260822052046_debt_payment_idempotency.sql';

  test('migracion v2 protege pagos con request_id persistente', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.pagos_deuda_requests'));
    expect(sql, contains('request_id uuid PRIMARY KEY'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS request_id uuid'));
    expect(sql, contains('pagos_venta_request_id_uidx'));
    expect(sql, contains('pagos_gasto_request_id_uidx'));
    expect(sql, contains('CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2'));
    expect(sql, contains('ON CONFLICT (request_id) DO NOTHING'));
    expect(sql, contains('FOR UPDATE'));
    expect(sql, contains("IN ('admin', 'operador')"));
    expect(sql, contains("jsonb_build_object('idempotent', true)"));
    expect(sql, contains('REVOKE ALL ON TABLE public.pagos_deuda_requests'));
  });

  test('pago a proveedor falla cerrado contra Caja Chica', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('v_saldo_disponible'));
    expect(sql, contains('v_sesion.monto_apertura'));
    expect(sql, contains('v_ingresos_efectivo'));
    expect(sql, contains('v_egresos_gastos'));
    expect(sql, contains('v_egresos_personal'));
    expect(sql, contains('Saldo insuficiente en Caja Chica'));
    expect(sql, contains('LIMIT 1 FOR UPDATE;'));
    expect(
      sql,
      contains('no puede ser anterior a la apertura de la caja'),
    );
  });

  test('flag de Caja Chica solo aplica a proveedor en efectivo', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(sql, contains('AND NOT p_es_cliente'));
    expect(sql, contains('AND v_es_efectivo'));
    expect(sql, contains('afecta_caja_chica,'));
    expect(sql, contains('v_descontar_de_caja,'));
  });

  test('migracion nueva no reintroduce roles tecnicos legacy', () {
    final sql = repositoryFile(migrationPath).readAsStringSync().toLowerCase();

    expect(sql, isNot(contains("'vendedor'")));
    expect(sql, isNot(contains("'almacenero'")));
    expect(sql, isNot(contains("'supervisor'")));
    expect(sql, isNot(contains("'administrador'")));
  });

  test('rollout mantiene RPC legacy hasta actualizar clientes', () {
    final sql = repositoryFile(migrationPath).readAsStringSync();

    expect(
      sql,
      isNot(contains('DROP FUNCTION IF EXISTS public.procesar_pago_deuda(')),
    );
    expect(
      sql,
      isNot(contains('REVOKE ALL ON FUNCTION public.procesar_pago_deuda(')),
    );
  });

  test('Flutter usa v2 y conserva intent antes de invocar Supabase', () {
    final repository = coreFile(
      'lib/features/deudas/data/deudas_repository.dart',
    ).readAsStringSync();
    final store = coreFile(
      'lib/features/deudas/data/debt_payment_request_store.dart',
    ).readAsStringSync();

    expect(repository, contains("'procesar_pago_deuda_v2'"));
    expect(repository, contains("'p_request_id': intent.requestId"));
    expect(repository, contains('getOrCreate('));
    expect(repository, contains('markConfirmed(fingerprint)'));
    expect(store, contains('SharedPreferences'));
    expect(store, contains('authUserId'));
    expect(store, contains('saldoActual'));
  });
}
