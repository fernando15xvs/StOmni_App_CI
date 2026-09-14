BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(24);

SELECT ok(to_regclass('public.cash_registers') IS NOT NULL,'cash_registers existe');
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.cash_registers'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),
  'cash_registers.organization_id NOT NULL'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.cash_registers'::regclass AND attname='branch_id' AND attnotnull AND NOT attisdropped),
  'cash_registers.branch_id NOT NULL'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.cash_registers'::regclass AND conname='cash_registers_organization_branch_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, branch_id)%branches(organization_id, id)%'),
  'cash register referencia branch con tenant'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='cash_registers' AND policyname='cash_registers_tenant_select' AND lower(qual) LIKE '%row_belongs_to_current_organization(organization_id)%'),
  'cash_registers SELECT aislado por tenant'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.sesiones_caja'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),
  'sesiones_caja.organization_id NOT NULL'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.sesiones_caja'::regclass AND attname='branch_id' AND attnotnull AND NOT attisdropped),
  'sesiones_caja.branch_id NOT NULL'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.sesiones_caja'::regclass AND attname='cash_register_id' AND attnotnull AND NOT attisdropped),
  'sesiones_caja.cash_register_id NOT NULL'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='sesiones_caja' AND indexname='sesiones_caja_one_open_per_register_key' AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%organization_id%' AND indexdef ILIKE '%cash_register_id%' AND indexdef ILIKE '%estado%ABIERTA%'),
  'una sesión ABIERTA por caja/tenant'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='sesiones_caja' AND policyname='sesiones_caja_tenant_select' AND lower(qual) LIKE '%row_belongs_to_current_organization(organization_id)%'),
  'sesiones_caja SELECT tenant-aware'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='sesiones_caja' AND policyname='sesiones_caja_tenant_insert' AND lower(with_check) LIKE '%usuario_id = auth.uid()%'),
  'sesión nueva pertenece al usuario autenticado'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.pagos_venta'::regclass AND attname='cash_session_id' AND NOT attisdropped),
  'pagos_venta.cash_session_id existe'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.pagos_gasto'::regclass AND attname='cash_session_id' AND NOT attisdropped),
  'pagos_gasto.cash_session_id existe'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pagos_venta'::regclass AND conname='pagos_venta_organization_cash_session_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%cash_register_id%cash_session_id%'),
  'pago venta referencia sesión tenant-qualified'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pagos_gasto'::regclass AND conname='pagos_gasto_organization_cash_session_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%cash_register_id%cash_session_id%'),
  'pago gasto referencia sesión tenant-qualified'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pagos_venta'::regclass AND tgname='zz_pagos_venta_enforce_cash_session' AND NOT tgisinternal),
  'trigger atribuye pagos de venta a sesión'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pagos_gasto'::regclass AND tgname='zz_pagos_gasto_enforce_cash_session' AND NOT tgisinternal),
  'trigger atribuye pagos de gasto a sesión'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='require_open_cash_session_id' AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%usuario_id=auth.uid()%'),
  'helper de sesión resuelve tenant+usuario'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='cash_session_available_balance' AND lower(pg_get_functiondef(p.oid)) LIKE '%cash_session_id=p_session_id%'),
  'saldo se calcula por cash_session_id'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pagos_deuda_requests'::regclass AND conname='pagos_deuda_requests_pkey' AND contype='p' AND pg_get_constraintdef(oid) ILIKE '%PRIMARY KEY (organization_id, request_id)%'),
  'idempotencia deuda tiene PK tenant/request'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procesar_pago_deuda_v2' AND lower(pg_get_functiondef(p.oid)) LIKE '%where organization_id=v_org and request_id=p_request_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%cash_session_id%'),
  'procesar_pago_deuda_v2 es tenant/session-aware'
);
SELECT ok(
  NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN information_schema.routine_privileges rp ON rp.specific_schema=n.nspname AND rp.routine_name=p.proname WHERE n.nspname='public' AND p.proname='_legacy_procesar_pago_deuda_v2' AND rp.grantee IN ('PUBLIC','anon','authenticated') AND rp.privilege_type='EXECUTE'),
  'motor legacy de deuda no es ejecutable por cliente'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='movimientos' AND c.relkind='v' AND array_to_string(c.reloptions,',') ILIKE '%security_invoker=true%'),
  'movimientos usa security_invoker'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='reportes_movimientos_financieros' AND c.relkind='v' AND array_to_string(c.reloptions,',') ILIKE '%security_invoker=true%'),
  'reportes_movimientos_financieros usa security_invoker'
);

SELECT * FROM finish();
ROLLBACK;
