-- 2D-G: legacy SECURITY DEFINER role lookup cannot leak another
-- organization's employee role. All fixtures are synthetic and rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(19);
CREATE TEMP TABLE _2dg_ctx(
 org uuid, other_org uuid,branch uuid,other_branch uuid,actor uuid
) ON COMMIT DROP;
INSERT INTO _2dg_ctx VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
 SELECT org,'2D-G synthetic tenant A','PE','PEN','America/Lima' FROM _2dg_ctx
 UNION ALL SELECT other_org,'2D-G synthetic tenant B','PE','PEN','America/Lima' FROM _2dg_ctx;
INSERT INTO auth.users(id,aud,role)
 SELECT actor,'authenticated','authenticated' FROM _2dg_ctx;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
 SELECT actor,org,'active','operador' FROM _2dg_ctx;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
 SELECT branch,org,'MAIN','Original branch',true,'active' FROM _2dg_ctx
 UNION ALL SELECT other_branch,other_org,'MAIN','Foreign branch',true,'active' FROM _2dg_ctx;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
 SELECT -840160101,org,branch,actor,actor,'Own employee','operador',true,'active'
 FROM _2dg_ctx
 UNION ALL SELECT -840160102,other_org,other_branch,actor,NULL,
 'Other organization employee','admin',true,'active' FROM _2dg_ctx;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
 SELECT gen_random_uuid(),org,'admin','2DG fixture admin',true,'active' FROM _2dg_ctx;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
 SELECT c.org,-840160101,r.id FROM _2dg_ctx c
 JOIN public.roles r ON r.organization_id=c.org AND r.code='admin';
-- Two comparable movements and prices in different tenants prove isolation
-- even though the privileged SQL function can bypass table-level RLS.
-- public.movimientos is a UNION ALL view; insert into its payments source.
INSERT INTO public.pagos_venta(id,organization_id,metodo,monto,fecha)
 SELECT -840160301,org,'transferencia',100,now() FROM _2dg_ctx
 UNION ALL SELECT -840160302,other_org,'transferencia',900,now() FROM _2dg_ctx;
INSERT INTO public.productos(
 id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,
 permitir_sin_stock,activo,es_servicio,item_type
)
 SELECT -840160401,org,'2D-G own product',100,100,'UNIDAD',false,true,false,'stock_product' FROM _2dg_ctx
 UNION ALL SELECT -840160402,other_org,'2D-G foreign product',900,900,'UNIDAD',false,true,false,'stock_product' FROM _2dg_ctx;
SET LOCAL session_replication_role=origin;

CREATE FUNCTION pg_temp._2dg_effective_permissions_rejected()
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM public.get_my_effective_permissions_v1();
 RETURN false;
EXCEPTION WHEN SQLSTATE '42501' THEN RETURN true;
END $fn$;

CREATE FUNCTION pg_temp._2dg_foreign_price_rejected()
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM public.resolve_sale_price_v1(-840160402,'unidad',1,now());
 RETURN false;
EXCEPTION WHEN OTHERS THEN RETURN true;
END $fn$;

SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2dg_ctx),true);
SELECT is(public.get_user_role(),'operador',
 'active member obtains own tenant operator role, not foreign admin');
SELECT ok(public.app_tiene_permiso('sales.create') IS TRUE,
 'active employee with tenant admin role receives sales permission');
SELECT ok((SELECT count(*)=2 FROM public.productos p WHERE p.id IN(-840160401,-840160402)),
 'two synthetic products exist in separate tenants');
SELECT ok((SELECT coalesce(sum(total),0)=100
 FROM public.obtener_tendencia_movimientos('ingreso',now()-interval '1 day',now()+interval '1 day')),
 'movement trend includes only current tenant 100, excludes foreign 900');
SELECT ok((SELECT count(*)=1 FROM public.obtener_tendencia_movimientos(
 'ingreso',now()-interval '1 day',now()+interval '1 day')),
 'movement trend returns only local date grouping');
SELECT ok((public.resolve_sale_price_v1(-840160401,'unidad',1,now())->>'price')::numeric=100,
 'own tenant product price resolves normally');
SELECT ok(pg_temp._2dg_foreign_price_rejected(),
 'privileged sale price resolver refuses foreign tenant product ID');
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false WHERE id=-840160101;
SET LOCAL session_replication_role=origin;
SELECT ok(public.get_user_role() IS NULL,
 'inactive local employee does not fall back to foreign admin role');
SELECT ok(public.app_tiene_permiso('sales.create') IS FALSE,
 'inactive account flag blocks effective sales permission');
SELECT ok(pg_temp._2dg_effective_permissions_rejected(),
 'inactive account flag blocks effective permissions RPC');
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=true WHERE id=-840160101;
SET LOCAL session_replication_role=origin;
SELECT is(public.get_user_role(),'operador','restored local employee returns its own role');
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET employment_status='terminated' WHERE id=-840160101;
SET LOCAL session_replication_role=origin;
SELECT ok(public.app_tiene_permiso('sales.create') IS FALSE,
 'terminated employment blocks sales permission even when activo=true');
SELECT ok(public._gre_empleado_activo() IS FALSE,
 'terminated employment blocks privileged active-employee helper');
SELECT ok(public.get_user_role() IS NULL,
 'terminated employment blocks tenant-scoped legacy role');
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET employment_status='active' WHERE id=-840160101;
SET LOCAL session_replication_role=origin;
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET status='disabled' WHERE user_id=(SELECT actor FROM _2dg_ctx);
SET LOCAL session_replication_role=origin;
SELECT ok(public.get_user_role() IS NULL,'disabled tenant membership denies legacy role lookup');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET status='active' WHERE user_id=(SELECT actor FROM _2dg_ctx);
SET LOCAL session_replication_role=origin;
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT ok(public.get_user_role() IS NULL,'non-member identity never receives employee role');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2dg_ctx),true);
SELECT ok(has_function_privilege('authenticated','public.get_user_role()','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_user_role()','EXECUTE')
 AND NOT has_function_privilege('service_role','public.get_user_role()','EXECUTE'),
 'definer role RPC remains authenticated-only');
SELECT ok((SELECT p.prosecdef AND 'search_path=""'=ANY(p.proconfig)
 FROM pg_proc p WHERE p.oid='public.get_user_role()'::regprocedure),
 'legacy role RPC has fixed search_path and intended privileged executor');
GRANT SELECT,INSERT ON _2dg_ctx TO authenticated;
CREATE TEMP TABLE _2dg_role_result(role_text text) ON COMMIT DROP;
GRANT SELECT,INSERT ON _2dg_role_result TO authenticated;
SET LOCAL ROLE authenticated;
INSERT INTO _2dg_role_result SELECT public.get_user_role();
RESET ROLE;
SELECT is((SELECT role_text FROM _2dg_role_result),'operador',
 'actual authenticated role can execute tenant-scoped RPC safely');
SELECT * FROM finish();
ROLLBACK;
