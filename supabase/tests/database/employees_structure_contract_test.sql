BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(20);

SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.empleados'::regclass AND attname='organization_id' AND NOT attisdropped),'empleados tiene organization_id');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.empleados'::regclass AND attname='app_user_id' AND NOT attisdropped),'empleados tiene app_user_id opcional');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.empleados'::regclass AND attname='branch_id' AND attnotnull AND NOT attisdropped),'empleados.branch_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.empleados'::regclass AND attname='employment_status' AND attnotnull AND NOT attisdropped),'estado laboral obligatorio');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.empleados'::regclass AND conname='empleados_organization_branch_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%branch_id%branches%organization_id%id%'),'empleado referencia branch por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.empleados'::regclass AND conname='empleados_organization_app_user_fkey'),'login empleado sigue tenant-safe y opcional');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.empleados'::regclass AND tgname='zz_empleados_branch_status' AND NOT tgisinternal),'trigger laboral activo');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.pagos_empleados'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'pagos_empleados.organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.pagos_empleados'::regclass AND attname='empleado_id' AND attnotnull AND NOT attisdropped),'pagos_empleados.empleado_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.pagos_empleados'::regclass AND attname='cash_session_id' AND NOT attisdropped),'pagos_empleados.cash_session_id existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pagos_empleados'::regclass AND conname='pagos_empleados_organization_employee_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%empleado_id%empleados%organization_id%id%'),'pago empleado usa FK tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pagos_empleados'::regclass AND conname='pagos_empleados_organization_cash_session_fkey'),'pago empleado usa sesión tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='pagos_empleados' AND policyname='pagos_empleados_tenant_admin_select' AND lower(qual) LIKE '%tenant.admin%' AND lower(qual) LIKE '%row_belongs_to_current_organization(organization_id)%'),'RLS de pagos de personal es admin+tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pagos_empleados'::regclass AND tgname='pagos_empleados_enforce_context' AND NOT tgisinternal),'trigger tenant/cash en pagos empleados');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='registrar_pago_empleado_mixto' AND lower(pg_get_functiondef(p.oid)) LIKE '%e.organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%require_open_cash_session_id()%'),'RPC pago empleado deriva tenant y sesión');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='cash_session_available_balance' AND lower(pg_get_functiondef(p.oid)) LIKE '%from public.pagos_empleados p%' AND lower(pg_get_functiondef(p.oid)) LIKE '%cash_session_id=p_session_id%'),'saldo Caja incluye pagos de personal por sesión');
SELECT ok(EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='movimientos' AND c.relkind='v' AND array_to_string(c.reloptions,',') ILIKE '%security_invoker=true%'),'movimientos sigue security_invoker');
SELECT ok(EXISTS(SELECT 1 FROM pg_views WHERE schemaname='public' AND viewname='movimientos' AND lower(definition) LIKE '%pagos_empleados%'),'movimientos reincorpora pagos empleados');
SELECT ok(EXISTS(SELECT 1 FROM pg_views WHERE schemaname='public' AND viewname='reportes_movimientos_financieros' AND lower(definition) LIKE '%pagos_empleados%'),'reporte financiero reincorpora pagos empleados');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_estado_caja_chica' AND lower(pg_get_functiondef(p.oid)) LIKE '%from public.pagos_empleados p%' AND lower(pg_get_functiondef(p.oid)) LIKE '%cash_session_id=v_session.id%'),'estado Caja incluye personal sólo de la sesión');

SELECT * FROM finish();
ROLLBACK;
