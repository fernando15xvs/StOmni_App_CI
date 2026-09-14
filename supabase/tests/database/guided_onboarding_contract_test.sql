BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

SELECT ok(to_regclass('public.organization_onboarding_progress') IS NOT NULL,'tabla onboarding existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_onboarding_progress'::regclass AND contype='p' AND pg_get_constraintdef(oid) ILIKE '%organization_id%'),'organization_id es PK');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_onboarding_progress'::regclass AND pg_get_constraintdef(oid) ILIKE '%organizations(id)%'),'FK organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.organization_onboarding_progress'::regclass AND attname='completed_steps' AND attnotnull AND NOT attisdropped),'completed_steps NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.organization_onboarding_progress'::regclass AND attname='revision' AND attnotnull AND NOT attisdropped),'revision NOT NULL');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.organization_onboarding_progress'::regclass),'RLS habilitada');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='organization_onboarding_progress' AND lower(qual) LIKE '%row_belongs_to_current_organization%'),'policy tenant-aware');
SELECT ok(has_table_privilege('authenticated','public.organization_onboarding_progress','SELECT'),'authenticated SELECT');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_onboarding_progress','INSERT'),'authenticated sin INSERT');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_onboarding_progress','UPDATE'),'authenticated sin UPDATE');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_onboarding_progress','DELETE'),'authenticated sin DELETE');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='organizations_create_onboarding_progress' AND NOT tgisinternal),'trigger para tenants nuevos');
SELECT ok(to_regprocedure('public.get_my_onboarding_progress_v1()') IS NOT NULL,'RPC lectura existe');
SELECT ok(to_regprocedure('public.complete_my_onboarding_step_v1(bigint,text)') IS NOT NULL,'RPC completar existe');
SELECT ok(has_function_privilege('authenticated','public.get_my_onboarding_progress_v1()','EXECUTE'),'authenticated lee progreso');
SELECT ok(has_function_privilege('authenticated','public.complete_my_onboarding_step_v1(bigint,text)','EXECUTE'),'authenticated ejecuta RPC controlado');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%tenant.admin%','mutación exige admin');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%p_expected_revision<>v_row.revision%','optimistic concurrency');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%steps must be completed in order%','secuencia forzada');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%public.configuracion_negocio%','perfil valida fuente autoritativa');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%public.business_capabilities%','módulos validan fuente autoritativa');
SELECT ok(pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%public.branches%' AND pg_get_functiondef('public.complete_my_onboarding_step_v1(bigint,text)'::regprocedure) ILIKE '%public.cash_registers%','operaciones valida branch/cash');

SELECT * FROM finish();
ROLLBACK;
