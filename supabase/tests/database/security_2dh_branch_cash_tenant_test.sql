-- 2D-H: exercise API grants and definer bodies as real authenticated callers.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SELECT plan(23);

CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT label, base_role, employee_id, product_id, gen_random_uuid() AS org,
       gen_random_uuid() AS actor, gen_random_uuid() AS branch, gen_random_uuid() AS role_id
FROM (VALUES
  ('A','admin',-840170101::bigint,840170401::bigint),
  ('B','operador',-840170102::bigint,840170402::bigint)
) AS fixture(label, base_role, employee_id, product_id);
GRANT SELECT ON actors TO authenticated;

-- Bypass provisioning triggers only while building the two isolated fixtures.
SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2DH tenant ' || label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role)
SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active',base_role FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Fixture branch',true,'active' FROM actors;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Fixture employee',base_role,true,'active' FROM actors;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
SELECT role_id,org,CASE label WHEN 'A' THEN 'admin' ELSE 'operator' END,'Fixture role',true,'active' FROM actors;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT org,employee_id,role_id FROM actors;
INSERT INTO public.cash_registers(id,organization_id,branch_id,code,name,is_default,status)
SELECT role_id,org,branch,'MAIN','Fixture register',true,'active' FROM actors;
INSERT INTO public.sesiones_caja(organization_id,branch_id,cash_register_id,usuario_id,monto_apertura,estado)
SELECT org,branch,role_id,actor,0,'ABIERTA' FROM actors;
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($$SELECT public.update_branch_v1((SELECT branch FROM actors WHERE label='B'),'Hidden',NULL,'active')$$,'P0002',NULL,'Foreign branch update');
SELECT throws_ok($$SELECT public.set_main_branch_v1((SELECT branch FROM actors WHERE label='B'))$$,'P0002',NULL,'Foreign main branch');
SELECT throws_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='B'),'Hidden','active')$$,'P0002',NULL,'Foreign active register update');
SELECT throws_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='B'),'Hidden','inactive')$$,'P0002',NULL,'Foreign open session remains undisclosed');
SELECT throws_ok($$SELECT public.set_default_cash_register_v1((SELECT role_id FROM actors WHERE label='B'))$$,'P0002',NULL,'Foreign default register');
SELECT throws_ok($$SELECT public.update_cash_register_v1(gen_random_uuid(),'Hidden','inactive')$$,'P0002',NULL,'Missing register matches foreign register');
SELECT lives_ok($$SELECT public.update_branch_v1((SELECT branch FROM actors WHERE label='A'),'Updated branch',NULL,'active')$$,'Admin can update its branch');
SELECT lives_ok($$SELECT public.set_main_branch_v1((SELECT branch FROM actors WHERE label='A'))$$,'Admin can select its main branch');
SELECT lives_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='A'),'Updated register','active')$$,'Admin can rename its open register');
SELECT lives_ok($$SELECT public.set_default_cash_register_v1((SELECT role_id FROM actors WHERE label='A'))$$,'Admin can select its default register');
SELECT throws_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='A'),'Hidden','inactive')$$,'23514','Cash register has an open session','Own open session still prevents deactivation');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($$SELECT public.update_branch_v1((SELECT branch FROM actors WHERE label='B'),'Hidden',NULL,'active')$$,'42501',NULL,'Operator denied own resource operation 1');
SELECT throws_ok($$SELECT public.set_main_branch_v1((SELECT branch FROM actors WHERE label='B'))$$,'42501',NULL,'Operator denied own resource operation 2');
SELECT throws_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='B'),'Hidden','active')$$,'42501',NULL,'Operator denied own resource operation 3');
SELECT throws_ok($$SELECT public.set_default_cash_register_v1((SELECT role_id FROM actors WHERE label='B'))$$,'42501',NULL,'Operator denied own resource operation 4');
RESET ROLE;
SELECT ok((SELECT name='Fixture branch' AND is_main AND status='active' FROM public.branches WHERE id=(SELECT branch FROM actors WHERE label='B')),'Foreign branch remains intact');
SELECT ok((SELECT name='Fixture register' AND is_default AND status='active' FROM public.cash_registers WHERE id=(SELECT role_id FROM actors WHERE label='B')),'Foreign register remains intact');
SELECT ok((SELECT count(*)=2 FROM public.sesiones_caja s JOIN actors a ON s.organization_id=a.org WHERE estado='ABIERTA' AND monto_apertura=0),'Both open sessions remain intact');
SELECT ok((SELECT name='Updated branch' FROM public.branches WHERE id=(SELECT branch FROM actors WHERE label='A')),'Own branch update persisted within transaction');
SELECT ok((SELECT name='Updated register' AND status='active' FROM public.cash_registers WHERE id=(SELECT role_id FROM actors WHERE label='A')),'Rejected deactivation preserves own register');
SET LOCAL session_replication_role = replica;
UPDATE public.sesiones_caja SET estado='CERRADA',fecha_cierre=now() WHERE organization_id=(SELECT org FROM actors WHERE label='A');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='A'),'Closed register','inactive')$$,'23514','default cash register must be active','Default register must remain active after session closes');
RESET ROLE;
-- Prepare a non-default local register to exercise successful deactivation.
SET LOCAL session_replication_role = replica;
UPDATE public.cash_registers SET is_default=false WHERE id=(SELECT role_id FROM actors WHERE label='A');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.update_cash_register_v1((SELECT role_id FROM actors WHERE label='A'),'Closed register','inactive')$$,'Own closed session permits deactivation');
RESET ROLE;
SELECT ok((SELECT status='inactive' FROM public.cash_registers WHERE id=(SELECT role_id FROM actors WHERE label='A')),'Own register becomes inactive');
SELECT * FROM finish();
ROLLBACK;
