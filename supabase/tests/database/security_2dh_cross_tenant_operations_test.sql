-- 2D-H: exercise API grants and definer bodies as real authenticated callers.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SELECT plan(43);

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
INSERT INTO public.productos(id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,
                             permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id,org,'Fixture product',10,10,'UNIDAD',false,true,false,'stock_product' FROM actors;
INSERT INTO public.product_unit_profiles(product_id,organization_id,revision,profile)
SELECT product_id,org,1,'{"schema_version":2}'::jsonb FROM actors;
-- Each table uses the fixture product_id as its own deterministic row identifier.
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre)
SELECT product_id,org,branch,'Fixture warehouse' FROM actors;
INSERT INTO public.ventas(id,organization_id,total,saldo)
SELECT product_id,org,100.25,75.15 FROM actors;
INSERT INTO public.gastos(id,organization_id,monto,saldo)
SELECT product_id,org,100.25,75.15 FROM actors;
INSERT INTO public.pagos_venta(id,organization_id,venta_id,metodo,monto)
SELECT product_id,org,product_id,'transferencia',25.10 FROM actors;
INSERT INTO public.pagos_gasto(id,organization_id,gasto_id,metodo,monto)
SELECT product_id,org,product_id,'transferencia',25.10 FROM actors;
SET LOCAL session_replication_role = origin;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT ok(public.get_user_role()='admin',
  'A resolves its administrator');
SELECT ok((SELECT array_agg((entry->>'product_id')::bigint ORDER BY (entry->>'product_id')::bigint)
    FROM public.get_product_unit_profiles_v1(ARRAY[840170401,840170402]::bigint[]) AS entry)=ARRAY[840170401]::bigint[],
  'A mixed batch returns only its product');
SELECT ok((public.get_employee_permission_settings_v1(-840170101)->>'employee_id')::bigint=-840170101,
  'A reads its employee settings');
SELECT throws_ok($$SELECT public.get_employee_permission_settings_v1(-840170102)$$, 'P0002', NULL,
  'A cannot read the B employee');
SELECT throws_ok($$SELECT public.set_employee_roles_v1(-840170102,ARRAY[(SELECT role_id FROM actors WHERE label='B')])$$, 'P0002', NULL,
  'A cannot assign roles to the B employee');
SELECT throws_ok($$SELECT public.set_employee_roles_v1(-840170101,ARRAY[(SELECT role_id FROM actors WHERE label='B')])$$, 'P0002', NULL,
  'A cannot assign a B role to its own employee');
SELECT throws_ok($$SELECT public.set_role_permissions_v1((SELECT role_id FROM actors WHERE label='B'),ARRAY['products.update'])$$, 'P0002', NULL,
  'A cannot grant permissions on a B role');
SELECT throws_ok($$SELECT public.update_employee_permission_overrides_v1(-840170102,'{"products.update":true}')$$, 'P0002', NULL,
  'A cannot grant a permission override to the B employee');
SELECT throws_ok($$SELECT public.get_product_traceability_config_v1(840170402)$$, 'P0002', NULL,
  'A cannot read the B traceability configuration');
SELECT throws_ok($$SELECT public.save_product_traceability_config_v1(840170402,0,'lot',true)$$, 'P0002', NULL,
  'A cannot write the B traceability configuration');
SELECT ok((public.save_product_traceability_config_v1(840170401,0,'lot',true)->>'revision')::int=1,
  'A can configure its own product');

SELECT throws_ok($$SELECT public.anular_venta_v2(840170402,'fixture')$$, 'P0002', NULL,
  'Sale cancellation rejects the B sale');
SELECT throws_ok($$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,840170402,0.01,'transferencia',now())$$, 'P0002', NULL,
  'Customer payment rejects the B sale');
SELECT throws_ok($$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),false,840170402,0.01,'transferencia',now())$$, 'P0002', NULL,
  'Supplier payment rejects the B expense');
SELECT throws_ok($$SELECT public.eliminar_pago_venta_v1(840170402,840170402)$$, 'P0002', NULL,
  'Payment deletion rejects the B sale');
SELECT throws_ok($$SELECT public.eliminar_pago_gasto_v1(840170402,840170401)$$, 'P0002', NULL,
  'Expense payment deletion rejects mixed tenant identifiers');
SELECT throws_ok($$SELECT public.eliminar_gasto_v1(840170402)$$, 'P0002', NULL,
  'Expense deletion rejects the B expense');
SELECT throws_ok($$SELECT public.trasladar_stock_scaled_v4(gen_random_uuid(),840170401,840170401,840170402,1)$$, 'P0002', NULL,
  'Stock transfer rejects a B destination for an A product');
SELECT ok((public.eliminar_pago_venta_v1(840170402,840170401)->>'idempotent')::boolean,
  'Foreign payment on a local sale receives the absent-payment response');

SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT ok(public.get_user_role()='operador',
  'B resolves its operator');
SELECT ok((SELECT array_agg((entry->>'product_id')::bigint ORDER BY (entry->>'product_id')::bigint)
    FROM public.get_product_unit_profiles_v1(ARRAY[840170401,840170402]::bigint[]) AS entry)=ARRAY[840170402]::bigint[],
  'B mixed batch returns only its product');
SELECT throws_ok($$SELECT public.get_product_traceability_config_v1(840170401)$$, 'P0002', NULL,
  'B cannot read the A traceability configuration');
SELECT throws_ok($$SELECT public.save_product_traceability_config_v1(840170402,0,'lot',true)$$, '42501', NULL,
  'B lacks write permission even on its own product');
SELECT throws_ok($$SELECT public.update_employee_permission_overrides_v1(-840170102,'{"products.update":true}')$$, '42501', NULL,
  'B cannot escalate its own permissions');
SELECT throws_ok($$SELECT public.get_employee_permission_settings_v1(-840170101)$$, '42501', NULL,
  'B cannot inspect A employee permissions');
SELECT ok((public.get_product_traceability_config_v1(840170402)->>'revision')::int=0,
  'B retains its initial traceability configuration');
SELECT ok(NOT public.app_tiene_permiso('products.update'),
  'B retains its restricted effective permissions');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.ventas v JOIN actors a ON (v.organization_id,v.id)=(a.org,a.product_id) WHERE v.saldo=75.15)
      AND (SELECT count(*)=2 FROM public.gastos g JOIN actors a ON (g.organization_id,g.id)=(a.org,a.product_id) WHERE g.saldo=75.15),
  'Both sales and both expenses retain their original balances');
SELECT ok((SELECT count(*)=2 FROM public.pagos_venta p JOIN actors a ON (p.organization_id,p.id,p.venta_id)=(a.org,a.product_id,a.product_id) WHERE p.monto=25.10)
      AND (SELECT count(*)=2 FROM public.pagos_gasto p JOIN actors a ON (p.organization_id,p.id,p.gasto_id)=(a.org,a.product_id,a.product_id) WHERE p.monto=25.10),
  'Both tenants retain their original sale and expense payments');
-- 2D-H quotation-idempotency replay: two genuinely authorized admins,
-- distinct tenant resources, and duplicate request UUID in both writers.
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT product_id+100,org,'Quotation customer '||label FROM actors;
UPDATE public.productos SET tipo_venta='CAJA_UNIDADES',cantidad_por_caja=1,codigo='QUOTE-'||id::text
WHERE id IN (840170401,840170402);
UPDATE public.app_users SET base_role='admin'
WHERE organization_id=(SELECT org FROM actors WHERE label='B');
UPDATE public.empleados SET rol='admin'
WHERE organization_id=(SELECT org FROM actors WHERE label='B');
UPDATE public.roles SET code='admin'
WHERE organization_id=(SELECT org FROM actors WHERE label='B');
SET LOCAL session_replication_role=origin;
CREATE TEMP TABLE _quote_requests(label text,req uuid,quote bigint) ON COMMIT DROP;
INSERT INTO _quote_requests(label,req)
SELECT label,gen_random_uuid() FROM actors;
GRANT SELECT,UPDATE ON _quote_requests TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
UPDATE _quote_requests SET quote=(public.guardar_cotizacion_v2(req,840170501,20,now(),'Quote A',15,'[{"producto_id":840170401,"almacen_id":840170401,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')->>'cotizacion_id')::bigint
WHERE label='A';
SELECT ok((SELECT quote FROM _quote_requests WHERE label='A') IS NOT NULL,'A creates valid own quotation');
SELECT is((public.guardar_cotizacion_v2((SELECT req FROM _quote_requests WHERE label='A'),840170501,20,now(),'A own replay',15,'[{"producto_id":840170401,"almacen_id":840170401,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')->>'cotizacion_id')::bigint,
 (SELECT quote FROM _quote_requests WHERE label='A'),'A standard idempotent replay remains valid');
SELECT is((public.guardar_cotizacion_with_units_v2((SELECT req FROM _quote_requests WHERE label='A'),840170501,20,now(),'A units replay',15,'[{"producto_id":840170401,"almacen_id":840170401,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')->>'cotizacion_id')::bigint,
 (SELECT quote FROM _quote_requests WHERE label='A'),'A units idempotent replay remains valid');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.guardar_cotizacion_v2((SELECT req FROM _quote_requests WHERE label='A'),840170502,20,now(),'B collision',15,'[{"producto_id":840170402,"almacen_id":840170402,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')$q$,
 '23505','request_id belongs to another organization','B cannot replay A quote through standard writer');
SELECT throws_ok($q$SELECT public.guardar_cotizacion_with_units_v2((SELECT req FROM _quote_requests WHERE label='A'),840170502,20,now(),'B units collision',15,'[{"producto_id":840170402,"almacen_id":840170402,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')$q$,
 '23505','request_id belongs to another organization','B cannot replay A quote through units writer');
UPDATE _quote_requests SET quote=(public.guardar_cotizacion_with_units_v2(req,840170502,20,now(),'B own quote',15,'[{"producto_id":840170402,"almacen_id":840170402,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')->>'cotizacion_id')::bigint
WHERE label='B';
SELECT ok((SELECT quote FROM _quote_requests WHERE label='B') IS NOT NULL,'B writes its own quote with a different UUID');
SELECT is((public.guardar_cotizacion_v2((SELECT req FROM _quote_requests WHERE label='B'),840170502,20,now(),'B replay',15,'[{"producto_id":840170402,"almacen_id":840170402,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')->>'cotizacion_id')::bigint,
 (SELECT quote FROM _quote_requests WHERE label='B'),'B own replay remains valid');
SELECT throws_ok($q$SELECT public.eliminar_cotizacion_v2((SELECT quote FROM _quote_requests WHERE label='A'))$q$,
 'P0002',NULL,'B cannot delete A quotation');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_cotizacion_v2((SELECT quote FROM _quote_requests WHERE label='B'))$q$,
 'P0002',NULL,'A cannot delete B quotation');
SELECT throws_ok($q$SELECT public.guardar_cotizacion_v2(gen_random_uuid(),840170502,20,now(),'Foreign client',15,'[{"producto_id":840170401,"almacen_id":840170401,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')$q$,
 'P0002',NULL,'A cannot quote B customer');
SELECT throws_ok($q$SELECT public.guardar_cotizacion_v2(gen_random_uuid(),840170501,20,now(),'Foreign product',15,'[{"producto_id":840170402,"almacen_id":840170402,"cantidad":2,"tipo_unidad":"unidad","subtotal":20,"precio_unitario_comercial":10,"precio_unitario":10,"piezas_reales":2}]')$q$,
 'P0002',NULL,'A cannot use B product/warehouse');
SELECT ok((public.eliminar_cotizacion_v2((SELECT quote FROM _quote_requests WHERE label='A'))->>'success')::boolean,'A can delete its own pending quote');
RESET ROLE;
SELECT ok(NOT EXISTS(SELECT 1 FROM public.cotizaciones c WHERE c.id=(SELECT quote FROM _quote_requests WHERE label='A')),
 'Own quotation deletion removes only A header');
SELECT ok(EXISTS(SELECT 1 FROM public.cotizaciones c WHERE c.id=(SELECT quote FROM _quote_requests WHERE label='B')),
 'B quotation survives cross-tenant attempts');
SELECT * FROM finish();
ROLLBACK;
