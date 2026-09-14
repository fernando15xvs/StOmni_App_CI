BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

SELECT ok(to_regclass('public.permissions') IS NOT NULL,'permissions existe');
SELECT ok(to_regclass('public.roles') IS NOT NULL,'roles existe');
SELECT ok(to_regclass('public.role_permissions') IS NOT NULL,'role_permissions existe');
SELECT ok(to_regclass('public.employee_roles') IS NOT NULL,'employee_roles existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.roles'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'roles.organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.roles'::regclass AND conname='roles_organization_id_key'),'roles expone clave tenant compuesta');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.role_permissions'::regclass AND conname='role_permissions_role_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%role_id%roles%organization_id%id%'),'role_permissions FK tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.employee_roles'::regclass AND conname='employee_roles_employee_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%employee_id%empleados%organization_id%id%'),'employee_roles employee tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.employee_roles'::regclass AND conname='employee_roles_role_fkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%role_id%roles%organization_id%id%'),'employee_roles role tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM public.permissions WHERE code='sales.create'),'catálogo contiene sales.create');
SELECT ok(EXISTS(SELECT 1 FROM public.permissions WHERE code='purchases.manage'),'catálogo contiene purchases.manage');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='trg_organization_create_system_roles' AND NOT tgisinternal),'nuevos tenants reciben roles sistema');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.empleados'::regclass AND tgname='empleados_assign_default_role' AND NOT tgisinternal),'nuevos empleados reciben rol inicial');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.employee_permission_overrides'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'overrides.organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.employee_permission_overrides'::regclass AND conname='employee_permission_overrides_pkey' AND pg_get_constraintdef(oid) ILIKE '%organization_id%employee_id%permission_code%'),'PK overrides tenant-aware');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_policies
  WHERE schemaname='public' AND tablename='employee_permission_overrides'
    AND policyname='employee_permission_tenant_read'
    AND lower(coalesce(qual,'')) LIKE '%row_belongs_to_current_organization%'
    AND lower(coalesce(qual,'')) LIKE '%organization_id%'
),'override RLS filtra tenant explícito');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='app_tiene_permiso' AND lower(pg_get_functiondef(p.oid)) LIKE '%from public.employee_roles er%' AND lower(pg_get_functiondef(p.oid)) LIKE '%join public.role_permissions rp%'),'app_tiene_permiso usa RBAC configurable');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='app_tiene_permiso' AND lower(pg_get_functiondef(p.oid)) LIKE '%_app_role_base_permissions%'),'app_tiene_permiso no usa matriz hardcodeada');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='create_role_v1'),'create_role_v1 existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='set_role_permissions_v1'),'set_role_permissions_v1 existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='set_employee_roles_v1'),'set_employee_roles_v1 existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_employee_permission_overrides_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org%'),'RPC overrides tenant-aware');

SELECT * FROM finish();
ROLLBACK;
