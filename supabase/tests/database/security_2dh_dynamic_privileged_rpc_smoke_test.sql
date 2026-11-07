-- 2D-H: dynamic smoke/provenance check for every authenticated public SECURITY DEFINER API.
-- Typed-NULL calls are a guard smoke test, NOT a replacement for domain positive
-- and cross-tenant negative cases. All effects are reverted by ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(9);
CREATE TEMP TABLE _rpc2dh_probe(stage text,sig text,outcome text,sqlstate text,sample jsonb) ON COMMIT DROP;
GRANT SELECT,INSERT ON _rpc2dh_probe TO authenticated;
CREATE TEMP TABLE _rpc2dh_actor(org uuid,user_id uuid,branch uuid) ON COMMIT DROP;
INSERT INTO _rpc2dh_actor SELECT gen_random_uuid(),gen_random_uuid(),gen_random_uuid();
GRANT SELECT ON _rpc2dh_actor TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
 SELECT org,'Audit terminated fixture','PE','PEN','America/Lima' FROM _rpc2dh_actor;
INSERT INTO auth.users(id,aud,role)
 SELECT user_id,'authenticated','authenticated' FROM _rpc2dh_actor;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
 SELECT user_id,org,'active','admin' FROM _rpc2dh_actor;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
 SELECT branch,org,'MAIN','Audit branch',true,'active' FROM _rpc2dh_actor;
INSERT INTO public.empleados(organization_id,branch_id,app_user_id,auth_id,nombre,rol,activo,employment_status)
 SELECT org,branch,user_id,user_id,'Terminated fixture','admin',false,'inactive'
 FROM _rpc2dh_actor;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
DO $audit$
DECLARE v_stage text; r record; v_statement text; v_value jsonb; v_code text;
BEGIN
 FOR v_stage IN SELECT unnest(ARRAY['missing_membership','inactive_employee']) LOOP
   IF v_stage='missing_membership' THEN
     PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
   ELSE
     PERFORM set_config('request.jwt.claim.sub',(SELECT user_id::text FROM _rpc2dh_actor),true);
   END IF;
   FOR r IN
      SELECT p.oid::regprocedure::text AS signature,n.nspname,p.proname,
       (SELECT string_agg('NULL::'||pg_catalog.format_type(p.proargtypes[i],NULL),',' ORDER BY i)
        FROM generate_series(0,p.pronargs-1) i) AS args
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.prosecdef
        AND pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
      ORDER BY p.proname
   LOOP
     v_statement:=format('SELECT to_jsonb(v) FROM %I.%I(%s) AS v LIMIT 1',
                           r.nspname,r.proname,coalesce(r.args,''));
     BEGIN
       EXECUTE v_statement INTO v_value;
       INSERT INTO _rpc2dh_probe VALUES(v_stage,r.signature,
         CASE WHEN v_value IS NULL THEN 'NULL_OR_EMPTY' ELSE 'VALUE' END,NULL,v_value);
     EXCEPTION WHEN OTHERS THEN
       GET STACKED DIAGNOSTICS v_code=RETURNED_SQLSTATE;
       INSERT INTO _rpc2dh_probe VALUES(v_stage,r.signature,'REJECTED',v_code,NULL);
     END;
   END LOOP;
 END LOOP;
END $audit$;
RESET ROLE;
SELECT is((SELECT count(*)::int FROM _rpc2dh_probe WHERE stage='missing_membership'),101,'101 RPCs probed without membership');
SELECT is((SELECT count(*)::int FROM _rpc2dh_probe WHERE stage='inactive_employee'),101,'101 RPCs probed with revoked employee');
SELECT is_empty($q$
 SELECT sig FROM _rpc2dh_probe
 WHERE outcome='VALUE' AND sig NOT IN (
  '_gre_empleado_activo()','app_tiene_permiso(text)',
  'get_organization_signup_state_v1()','list_subscription_plans_v1()'
 )$q$,'No unexpected privileged RPC returns a value with typed NULL arguments');
SELECT is_empty($q$
 SELECT sig FROM _rpc2dh_probe
 WHERE outcome='VALUE' AND sig IN ('_gre_empleado_activo()','app_tiene_permiso(text)')
   AND sample IS DISTINCT FROM 'false'::jsonb$q$,
 'Employment and permission booleans fail closed');
SELECT is((SELECT count(*)::int FROM _rpc2dh_probe WHERE sig='get_organization_signup_state_v1()' AND outcome='VALUE'),2,'Public signup-state endpoint remains available for account recovery');
SELECT is((SELECT count(*)::int FROM _rpc2dh_probe WHERE sig='list_subscription_plans_v1()' AND outcome='VALUE'),2,'Public plan catalog remains available');
SELECT is_empty($q$
 SELECT p.oid::regprocedure::text FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
 AND p.prosecdef AND has_function_privilege('anon',p.oid,'EXECUTE')$q$,
 'Anonymous callers cannot execute public SECURITY DEFINER functions');
SELECT ok(NOT has_function_privilege('authenticated','private.refresh_operational_alerts_for_org(uuid)','EXECUTE'),'Privileged alert refresh helper stays private');
SELECT ok(NOT has_function_privilege('authenticated','private.upsert_operational_alert(uuid,text,text,text,text,text,text,text,timestamp with time zone,jsonb,timestamp with time zone)','EXECUTE'),'Privileged alert writer stays private');
SELECT * FROM finish();
ROLLBACK;
