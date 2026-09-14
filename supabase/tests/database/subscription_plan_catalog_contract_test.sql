BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT ok(to_regclass('public.subscription_plans') IS NOT NULL,'subscription_plans existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.subscription_plans'::regclass AND attname='code' AND attnotnull AND NOT attisdropped),'code NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.subscription_plans'::regclass AND contype='u' AND pg_get_constraintdef(oid) ILIKE '%code%'),'code único');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.subscription_plans'::regclass AND contype='u' AND pg_get_constraintdef(oid) ILIKE '%tier_rank%'),'tier_rank único');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.subscription_plans'::regclass AND pg_get_constraintdef(oid) ILIKE '%active%archived%'),'status restringido');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.subscription_plans'::regclass AND pg_get_constraintdef(oid) ILIKE '%pg_column_size(metadata)%8192%'),'metadata acotada');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.subscription_plans'::regclass),'RLS habilitada');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='subscription_plans' AND policyname='subscription_plans_public_read' AND lower(qual) LIKE '%status = ''active''%' AND lower(qual) LIKE '%is_public%'),'policy sólo visible/activo');
SELECT ok(has_table_privilege('authenticated','public.subscription_plans','SELECT'),'authenticated puede leer catálogo');
SELECT ok(NOT has_table_privilege('authenticated','public.subscription_plans','INSERT'),'authenticated sin INSERT');
SELECT ok(NOT has_table_privilege('authenticated','public.subscription_plans','UPDATE'),'authenticated sin UPDATE');
SELECT ok(NOT has_table_privilege('authenticated','public.subscription_plans','DELETE'),'authenticated sin DELETE');
SELECT is((SELECT count(*)::integer FROM public.subscription_plans WHERE code IN ('starter','business','pro','enterprise')),4,'cuatro códigos base sembrados');
SELECT ok((SELECT tier_rank FROM public.subscription_plans WHERE code='starter') < (SELECT tier_rank FROM public.subscription_plans WHERE code='business'),'starter antes de business');
SELECT ok((SELECT tier_rank FROM public.subscription_plans WHERE code='business') < (SELECT tier_rank FROM public.subscription_plans WHERE code='pro'),'business antes de pro');
SELECT ok((SELECT tier_rank FROM public.subscription_plans WHERE code='pro') < (SELECT tier_rank FROM public.subscription_plans WHERE code='enterprise'),'pro antes de enterprise');
SELECT ok(to_regprocedure('public.list_subscription_plans_v1()') IS NOT NULL,'RPC list_subscription_plans_v1 existe');
SELECT ok(has_function_privilege('authenticated','public.list_subscription_plans_v1()','EXECUTE'),'authenticated puede ejecutar list plans');

SELECT * FROM finish();
ROLLBACK;
