-- Two real synthetic tenant bootstraps + 22 reader RPCs per actor.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(19);
CREATE TEMP TABLE _reader_owner(label text,uid uuid,org uuid) ON COMMIT DROP;
INSERT INTO _reader_owner SELECT label,gen_random_uuid(),NULL::uuid FROM (VALUES('A'),('B')) t(label);
GRANT SELECT,UPDATE ON _reader_owner TO authenticated;
CREATE TEMP TABLE _reader_invocation(sig text,call_sql text) ON COMMIT DROP;
INSERT INTO _reader_invocation VALUES ('get_business_profile_v1()','get_business_profile_v1()'),
('get_current_business_configuration_v1()','get_current_business_configuration_v1()'),
('get_estado_caja_chica()','get_estado_caja_chica()'),
('get_my_subscription_v1()','get_my_subscription_v1()'),
('get_my_billing_summary_v1()','get_my_billing_summary_v1()'),
('get_my_effective_permissions_v1()','get_my_effective_permissions_v1()'),
('get_my_onboarding_progress_v1()','get_my_onboarding_progress_v1()'),
('get_business_assistant_settings_v1()','get_business_assistant_settings_v1()'),
('get_operational_alert_settings_v1()','get_operational_alert_settings_v1()'),
('get_user_role()','get_user_role()'),
('get_observability_metrics_v1(integer)','get_observability_metrics_v1(10)'),
('get_dashboard_summary(timestamp with time zone,timestamp with time zone)','get_dashboard_summary(now()-interval ''1 day'',now())'),
('get_configurable_dashboard_v1(timestamp with time zone,timestamp with time zone,uuid)','get_configurable_dashboard_v1(now()-interval ''1 day'',now(),NULL)'),
('get_my_entitlements_v1()','get_my_entitlements_v1()'),
('list_purchase_orders_v1(text,integer)','list_purchase_orders_v1(NULL,10)'),
('list_services_v1(boolean)','list_services_v1(true)'),
('list_custom_field_definitions_v1(text,boolean)','list_custom_field_definitions_v1(''catalog_item'',true)'),
('list_sale_price_rules_v1()','list_sale_price_rules_v1()'),
('list_business_metrics_v1()','list_business_metrics_v1()'),
('list_audit_logs_v1(integer,bigint,text,text)','list_audit_logs_v1(10,NULL,NULL,NULL)'),
('list_recent_observability_errors_v1(integer)','list_recent_observability_errors_v1(10)'),
('list_operational_alerts_v1(text,integer)','list_operational_alerts_v1(NULL,10)');
GRANT SELECT ON _reader_invocation TO authenticated;
CREATE TEMP TABLE _reader_probe(stage text,sig text,outcome text,error_code text,payload jsonb) ON COMMIT DROP;
GRANT SELECT,INSERT ON _reader_probe TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated','2dh-reader-'||uid||'@example.invalid',now() FROM _reader_owner;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
UPDATE _reader_owner SET org=(public.create_my_organization_v1('2DH reader tenant A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
UPDATE _reader_owner SET org=(public.create_my_organization_v1('2DH reader tenant B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
CREATE FUNCTION pg_temp._reader_check(p_stage text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record;v jsonb;c text;m text;
BEGIN
 FOR r IN SELECT sig,call_sql FROM _reader_invocation ORDER BY sig LOOP
  BEGIN
   EXECUTE format('SELECT coalesce(jsonb_agg(x),''[]''::jsonb) FROM (SELECT * FROM public.%s LIMIT 20) x',r.call_sql) INTO v;
   INSERT INTO _reader_probe VALUES(p_stage,r.sig,'ok',NULL,v);
  EXCEPTION WHEN OTHERS THEN
   GET STACKED DIAGNOSTICS c=RETURNED_SQLSTATE,m=MESSAGE_TEXT;
   INSERT INTO _reader_probe VALUES(p_stage,r.sig,'rejected',c,to_jsonb(left(m,160)));
  END;
 END LOOP;
END $f$;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT pg_temp._reader_check('A');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT pg_temp._reader_check('B');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive'
WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT pg_temp._reader_check('revoked');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT pg_temp._reader_check('unknown');
RESET ROLE;
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_invocation)),false),'22 reader entrypoints');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='A')),false),'A tested 22');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='B')),false),'B tested 22');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='revoked')),false),'revoked tested 22');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='unknown')),false),'unknown tested 22');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='A' AND outcome='ok')),false),'A positive 22');
SELECT ok(coalesce(((SELECT count(*)=22 FROM _reader_probe WHERE stage='B' AND outcome='ok')),false),'B positive 22');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage='A' AND payload::text LIKE '%'||(SELECT org::text FROM _reader_owner WHERE label='B')||'%')),false),'A cannot see B UUID');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage='B' AND payload::text LIKE '%'||(SELECT org::text FROM _reader_owner WHERE label='A')||'%')),false),'B cannot see A UUID');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage='A' AND payload::text LIKE '%2DH reader tenant B%')),false),'A cannot see B name');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage='B' AND payload::text LIKE '%2DH reader tenant A%')),false),'B cannot see A name');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage IN('revoked','unknown') AND outcome='ok' AND sig NOT IN ('get_user_role()','list_services_v1(boolean)'))),false),'No protected successes when revoked');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage IN('revoked','unknown') AND sig='get_user_role()' AND (outcome<>'ok' OR payload IS DISTINCT FROM '[{"get_user_role":null}]'::jsonb))),false),'Legacy role returns only NULL');
SELECT ok(coalesce((NOT EXISTS(SELECT 1 FROM _reader_probe WHERE stage IN('revoked','unknown') AND sig='list_services_v1(boolean)' AND (outcome<>'ok' OR payload IS DISTINCT FROM '[]'::jsonb))),false),'Services listing empty for revoked');
SELECT ok(coalesce(((SELECT count(*)=20 FROM _reader_probe WHERE stage='revoked' AND outcome='rejected')),false),'20 denied revoked');
SELECT ok(coalesce(((SELECT count(*)=20 FROM _reader_probe WHERE stage='unknown' AND outcome='rejected')),false),'20 denied unknown');
SELECT ok(coalesce(((SELECT (payload->0->'get_my_subscription_v1'->>'organization_id')::uuid FROM _reader_probe WHERE stage='A' AND sig='get_my_subscription_v1()') = (SELECT org FROM _reader_owner WHERE label='A')),false),'A subscription tenant');
SELECT ok(coalesce(((SELECT (payload->0->'get_my_subscription_v1'->>'organization_id')::uuid FROM _reader_probe WHERE stage='B' AND sig='get_my_subscription_v1()') = (SELECT org FROM _reader_owner WHERE label='B')),false),'B subscription tenant');
SELECT ok(coalesce(((SELECT count(*)=2 FROM _reader_probe WHERE stage IN('A','B') AND sig='get_user_role()' AND payload='[{"get_user_role":"admin"}]'::jsonb)),false),'Both owners admin');
SELECT * FROM finish();
ROLLBACK;
