BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(20);

SELECT ok(to_regclass('public.organization_subscriptions') IS NOT NULL,'organization_subscriptions existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_subscriptions'::regclass AND contype='p' AND pg_get_constraintdef(oid) ILIKE '%organization_id%'),'organization_id es PK');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_subscriptions'::regclass AND pg_get_constraintdef(oid) ILIKE '%organizations(id)%'),'FK organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_subscriptions'::regclass AND pg_get_constraintdef(oid) ILIKE '%subscription_plans(id)%'),'FK plan');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.organization_subscriptions'::regclass AND pg_get_constraintdef(oid) ILIKE '%trialing%active%past_due%suspended%canceled%'),'status restringido');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.organization_subscriptions'::regclass AND attname='revision' AND attnotnull AND NOT attisdropped),'revision NOT NULL');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.organization_subscriptions'::regclass),'RLS habilitada');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='organization_subscriptions' AND policyname='organization_subscriptions_tenant_read' AND lower(qual) LIKE '%row_belongs_to_current_organization%'),'policy tenant read');
SELECT ok(has_table_privilege('authenticated','public.organization_subscriptions','SELECT'),'authenticated SELECT');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_subscriptions','INSERT'),'authenticated sin INSERT');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_subscriptions','UPDATE'),'authenticated sin UPDATE');
SELECT ok(NOT has_table_privilege('authenticated','public.organization_subscriptions','DELETE'),'authenticated sin DELETE');
SELECT ok(NOT EXISTS(SELECT organization_id FROM public.organization_subscriptions GROUP BY organization_id HAVING count(*)>1),'una fila por tenant');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.organizations o LEFT JOIN public.organization_subscriptions s ON s.organization_id=o.id WHERE s.organization_id IS NULL),'todos los tenants existentes tienen suscripción');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='organizations_create_default_subscription' AND NOT tgisinternal),'trigger default subscription');
SELECT ok(to_regprocedure('public.get_my_subscription_v1()') IS NOT NULL,'get_my_subscription_v1 existe');
SELECT ok(has_function_privilege('authenticated','public.get_my_subscription_v1()','EXECUTE'),'authenticated puede leer su suscripción');
SELECT ok(to_regprocedure('private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)') IS NOT NULL,'writer privado existe');
SELECT ok(NOT has_function_privilege('authenticated','private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)','EXECUTE'),'authenticated no ejecuta writer');
SELECT ok(has_function_privilege('service_role','private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)','EXECUTE'),'service_role ejecuta writer');

SELECT * FROM finish();
ROLLBACK;
