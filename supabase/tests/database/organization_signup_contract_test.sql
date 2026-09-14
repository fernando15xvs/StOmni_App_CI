BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT ok(to_regprocedure('public.get_organization_signup_state_v1()') IS NOT NULL,'RPC estado de alta existe');
SELECT ok(to_regprocedure('public.create_my_organization_v1(text,text,text,text,text)') IS NOT NULL,'RPC alta autoservicio existe');
SELECT ok(has_function_privilege('authenticated','public.get_organization_signup_state_v1()','EXECUTE'),'authenticated puede consultar estado pre-tenant');
SELECT ok(has_function_privilege('authenticated','public.create_my_organization_v1(text,text,text,text,text)','EXECUTE'),'authenticated puede crear su empresa');
SELECT ok(NOT has_function_privilege('anon','public.get_organization_signup_state_v1()','EXECUTE'),'anon no consulta estado');
SELECT ok(NOT has_function_privilege('anon','public.create_my_organization_v1(text,text,text,text,text)','EXECUTE'),'anon no crea empresa');
SELECT ok(NOT has_function_privilege('authenticated','public.bootstrap_organization_v1(text,text,text,text,text)','EXECUTE'),'bootstrap técnico no es entrypoint cliente');

SELECT ok(
  pg_get_functiondef('public.get_organization_signup_state_v1()'::regprocedure) ILIKE '%auth.uid()%'
  ,'estado deriva auth.uid()');
SELECT ok(
  pg_get_functiondef('public.get_organization_signup_state_v1()'::regprocedure) ILIKE '%legacy_identity_requires_migration%'
  ,'estado distingue identidad legacy');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) ILIKE '%bootstrap_organization_v1%'
  ,'alta reutiliza bootstrap F1.4');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) ILIKE '%set_organization_subscription_v1%'
  ,'alta asigna suscripción mediante writer autoritativo');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) ILIKE '%''starter''%'
  ,'alta autoservicio inicia en identidad Starter');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) ILIKE '%''bootstrap_default''%'
  ,'alta conserva razón bootstrap_default');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) NOT ILIKE '%p_organization_id%'
  ,'cliente no aporta organization_id');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) NOT ILIKE '%p_plan_code%'
  ,'cliente no aporta plan_code');
SELECT ok(
  pg_get_functiondef('public.create_my_organization_v1(text,text,text,text,text)'::regprocedure) NOT ILIKE '%EXCEPTION WHEN OTHERS%'
  ,'alta no oculta rollback con WHEN OTHERS');
SELECT ok(
  (SELECT prosecdef FROM pg_proc WHERE oid='public.create_my_organization_v1(text,text,text,text,text)'::regprocedure)
  ,'alta usa SECURITY DEFINER');
SELECT ok(
  (SELECT proconfig @> ARRAY['search_path=""']::text[] OR proconfig @> ARRAY['search_path=']::text[] FROM pg_proc WHERE oid='public.create_my_organization_v1(text,text,text,text,text)'::regprocedure)
  ,'alta fija search_path vacío');

SELECT * FROM finish();
ROLLBACK;
