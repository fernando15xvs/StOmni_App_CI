-- Two real synthetic tenant bootstraps + 22 reader RPCs per actor.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(56);
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
RESET ROLE;
-- Store foreign branch IDs in an explicitly shared TEMP fixture, never
-- retrieve them via the caller-scoped public.branches RLS (which returns NULL).
CREATE TEMP TABLE _scoped(label text,product bigint,warehouse bigint,br uuid,register uuid) ON COMMIT DROP;
INSERT INTO _scoped
SELECT u.label,CASE u.label WHEN 'A' THEN 840232401 ELSE 840232402 END,
CASE u.label WHEN 'A' THEN 840232501 ELSE 840232502 END,b.id,r.id
FROM _reader_owner u JOIN public.branches b ON b.organization_id=u.org AND b.is_main
JOIN public.cash_registers r ON r.organization_id=u.org AND r.is_default;
GRANT SELECT ON _scoped TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre,activo)
SELECT s.warehouse,u.org,s.br,'Warehouse '||s.label,true FROM _scoped s JOIN _reader_owner u ON u.label=s.label;
INSERT INTO public.productos(id,organization_id,codigo,nombre,precio_unidad,precio_caja,precio_compra,tipo_venta,cantidad_por_caja,permitir_sin_stock,activo,es_servicio,item_type,stock_minimo)
SELECT s.product,u.org,'DASH-'||s.label,'Dashboard Item '||s.label,15,15,5,'UNIDAD',1,false,true,false,'stock_product',
CASE s.label WHEN 'A' THEN 5 ELSE 8 END FROM _scoped s JOIN _reader_owner u ON u.label=s.label;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT u.org,s.product,s.warehouse,CASE s.label WHEN 'A' THEN 3 ELSE 1 END FROM _scoped s JOIN _reader_owner u ON u.label=s.label;
INSERT INTO public.pagos_venta(organization_id,metodo,monto,fecha,cash_register_id)
SELECT u.org,'transferencia',CASE s.label WHEN 'A' THEN 31 ELSE 67 END,now(),s.register
FROM _scoped s JOIN _reader_owner u ON u.label=s.label;
INSERT INTO public.pagos_gasto(organization_id,metodo,monto,fecha,cash_register_id)
SELECT u.org,'transferencia',CASE s.label WHEN 'A' THEN 4 ELSE 9 END,now(),s.register
FROM _scoped s JOIN _reader_owner u ON u.label=s.label;
UPDATE public.business_assistant_settings SET enabled=true,max_result_items=5,default_period_days=14
WHERE organization_id IN((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'));
INSERT INTO public.observability_events(organization_id,trace_id,component,event_name,severity,outcome,duration_ms,http_status,error_code)
SELECT org,gen_random_uuid(),'probe.'||lower(label),'probe.failed','error',CASE label WHEN 'A' THEN 'failed' ELSE 'denied' END,25,500,'SCOPE_TEST'
FROM _reader_owner;
INSERT INTO public.audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,source_table,source_operation,metadata)
SELECT org,uid,'probe.audit.'||lower(label),'scope_probe',label,'scope_probe','RPC',
jsonb_build_object('marker','audit-only-'||label) FROM _reader_owner;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT * FROM public.save_business_metrics_v1('[{"source":"income","label":"Revenue A","position":1,"enabled":true,"format":"currency"},{"source":"expenses","label":"Expense A","position":2,"enabled":true,"format":"currency"}]'::jsonb);
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'ingresos_hoy')::numeric,31::numeric,'A summary own payment income');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'egresos_hoy')::numeric,4::numeric,'A summary own payment expenses');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'total_productos')::int,1,'A summary only own products');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'low_stock_count')::int,1,'A low stock only own inventory');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)->'metrics'->0->>'value')::numeric,31::numeric,'A configurable income isolated');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)->'metrics'->1->>'value')::numeric,4::numeric,'A configurable expense isolated');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',(SELECT br FROM _scoped WHERE label='A'))->'metrics'->0->>'value')::numeric,31::numeric,'A branch income only own register');
SELECT throws_ok($q$SELECT public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',(SELECT br FROM _scoped WHERE label='B'))$q$,'P0002',NULL,'A foreign branch rejected');
SELECT is((SELECT count(*)::int FROM public.list_business_metrics_v1()),2,'A metrics list only own entries');
SELECT is((SELECT x->>'label' FROM public.list_business_metrics_v1() x WHERE x->>'source'='income'),'Revenue A','A own metric label');
SELECT is((public.get_business_assistant_context_v1('replenishment',14,NULL,5)->'items'->0->>'product_id')::bigint,840232401::bigint,'A replenishment own product');
SELECT is((public.get_business_assistant_context_v1('replenishment',14,NULL,5)->'items'->0->>'gap_to_minimum')::numeric,2::numeric,'A replenishment own gap');
SELECT is((public.get_business_assistant_context_v1('non_moving_products',14,NULL,5)->'items'->0->>'product_id')::bigint,840232401::bigint,'A nonmoving product own tenant');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('replenishment',14,(SELECT br FROM _scoped WHERE label='B'),5)$q$,'P0002',NULL,'A assistant foreign branch rejected');
SELECT is((public.get_observability_metrics_v1(24)->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A observability own tenant');
SELECT ok((public.get_observability_metrics_v1(24)->'components') @> '[{"component":"probe.a","events":1}]'::jsonb,'A observability own component');
SELECT ok(NOT((public.get_observability_metrics_v1(24)->'components') @> '[{"component":"probe.b"}]'::jsonb),'A foreign observability missing');
SELECT is((SELECT count(*)::int FROM public.list_recent_observability_errors_v1(100) e WHERE e.component='probe.a'),1,'A own error event');
SELECT is((SELECT count(*)::int FROM public.list_recent_observability_errors_v1(100) e WHERE e.component='probe.b'),0,'A no foreign error');
SELECT is((SELECT count(*)::int FROM public.list_audit_logs_v1(100,NULL,'probe.audit.a','scope_probe')),1,'A own audit event');
SELECT is((SELECT count(*)::int FROM public.list_audit_logs_v1(100,NULL,'probe.audit.b','scope_probe')),0,'A foreign audit inaccessible');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('replenishment',14,NULL,6)$q$,'22023',NULL,'Assistant enforces maximum result count');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('unknown',14,NULL,5)$q$,'22023',NULL,'Assistant intent validation');
SELECT throws_ok($q$SELECT * FROM public.list_audit_logs_v1(0,NULL,NULL,NULL)$q$,'22023',NULL,'Audit rejects zero limit');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT * FROM public.save_business_metrics_v1('[{"source":"income","label":"Revenue B","position":1,"enabled":true,"format":"currency"},{"source":"expenses","label":"Expense B","position":2,"enabled":true,"format":"currency"}]'::jsonb);
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'ingresos_hoy')::numeric,67::numeric,'B summary own payment income');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'egresos_hoy')::numeric,9::numeric,'B summary own payment expenses');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'total_productos')::int,1,'B summary only own products');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'low_stock_count')::int,1,'B low stock only own inventory');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)->'metrics'->0->>'value')::numeric,67::numeric,'B configurable income isolated');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)->'metrics'->1->>'value')::numeric,9::numeric,'B configurable expense isolated');
SELECT is((public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',(SELECT br FROM _scoped WHERE label='B'))->'metrics'->0->>'value')::numeric,67::numeric,'B branch income only own register');
SELECT throws_ok($q$SELECT public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',(SELECT br FROM _scoped WHERE label='A'))$q$,'P0002',NULL,'B foreign branch rejected');
SELECT is((SELECT count(*)::int FROM public.list_business_metrics_v1()),2,'B metrics list only own entries');
SELECT is((SELECT x->>'label' FROM public.list_business_metrics_v1() x WHERE x->>'source'='income'),'Revenue B','B own metric label');
SELECT is((public.get_business_assistant_context_v1('replenishment',14,NULL,5)->'items'->0->>'product_id')::bigint,840232402::bigint,'B replenishment own product');
SELECT is((public.get_business_assistant_context_v1('replenishment',14,NULL,5)->'items'->0->>'gap_to_minimum')::numeric,7::numeric,'B replenishment own gap');
SELECT is((public.get_business_assistant_context_v1('non_moving_products',14,NULL,5)->'items'->0->>'product_id')::bigint,840232402::bigint,'B nonmoving product own tenant');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('replenishment',14,(SELECT br FROM _scoped WHERE label='A'),5)$q$,'P0002',NULL,'B assistant foreign branch rejected');
SELECT is((public.get_observability_metrics_v1(24)->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B observability own tenant');
SELECT ok((public.get_observability_metrics_v1(24)->'components') @> '[{"component":"probe.b","events":1}]'::jsonb,'B observability own component');
SELECT ok(NOT((public.get_observability_metrics_v1(24)->'components') @> '[{"component":"probe.a"}]'::jsonb),'B foreign observability missing');
SELECT is((SELECT count(*)::int FROM public.list_recent_observability_errors_v1(100) e WHERE e.component='probe.b'),1,'B own error event');
SELECT is((SELECT count(*)::int FROM public.list_recent_observability_errors_v1(100) e WHERE e.component='probe.a'),0,'B no foreign error');
SELECT is((SELECT count(*)::int FROM public.list_audit_logs_v1(100,NULL,'probe.audit.b','scope_probe')),1,'B own audit event');
SELECT is((SELECT count(*)::int FROM public.list_audit_logs_v1(100,NULL,'probe.audit.a','scope_probe')),0,'B foreign audit inaccessible');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _reader_owner WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT throws_ok($q$SELECT (SELECT count(*) FROM public.list_business_metrics_v1())$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('replenishment',14,NULL,5)$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT throws_ok($q$SELECT public.get_observability_metrics_v1(24)$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT throws_ok($q$SELECT (SELECT count(*) FROM public.list_recent_observability_errors_v1(10))$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT throws_ok($q$SELECT (SELECT count(*) FROM public.list_audit_logs_v1(10,NULL,NULL,NULL))$q$,'42501',NULL,'B operator lacks admin analytics rights');
SELECT is((public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb->>'ingresos_hoy')::numeric,67::numeric,'B operator tenant read still own summary');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.get_dashboard_summary(now()-interval '1 day',now()+interval '1 day')::jsonb$q$,'42501',NULL,'Revoked A cannot read analytics');
SELECT throws_ok($q$SELECT public.get_configurable_dashboard_v1(now()-interval '1 day',now()+interval '1 day',NULL)$q$,'42501',NULL,'Revoked A cannot read analytics');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('replenishment',14,NULL,5)$q$,'42501',NULL,'Revoked A cannot read analytics');
SELECT throws_ok($q$SELECT public.get_observability_metrics_v1(24)$q$,'42501',NULL,'Revoked A cannot read analytics');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
