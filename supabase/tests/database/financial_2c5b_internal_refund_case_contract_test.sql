-- 2C5B-A: solicitudes pendientes de devolución. Datos reversibles.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE TEMP TABLE _fin2c2_f (
  org_a uuid, org_b uuid,
  sale_a bigint, sale_b bigint,
  request_a uuid, request_b uuid,
  payment_at timestamptz,
  payment_a bigint,
  op_a uuid
) ON COMMIT DROP;
INSERT INTO _fin2c2_f(org_a,org_b,sale_a,sale_b,request_a,request_b,payment_at)
 VALUES (gen_random_uuid(),gen_random_uuid(),-840030001,-840030002,
 gen_random_uuid(),gen_random_uuid(),now()-interval '1 hour');
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2C2 org A','PE','PEN','America/Lima' FROM _fin2c2_f
UNION ALL SELECT org_b,'2C2 org B','PE','PEN','America/Lima' FROM _fin2c2_f;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
SELECT sale_a,org_a,100,100,'pendiente',now()-interval '1 day',0 FROM _fin2c2_f
UNION ALL SELECT sale_b,org_b,50,50,'pendiente',now()-interval '1 day',0 FROM _fin2c2_f;
SET LOCAL session_replication_role=origin;
INSERT INTO public.venta_cuentas_financieras(
 organization_id,venta_id,moneda,estado_conciliacion,
 exigible,cobros_netos,saldo_pendiente,revision)
SELECT org_a,sale_a,'PEN','conciliada',100,0,100,1 FROM _fin2c2_f
UNION ALL SELECT org_b,sale_b,'PEN','conciliada',50,0,50,1 FROM _fin2c2_f;
WITH ins AS (
 INSERT INTO public.venta_operaciones_financieras(
  organization_id,venta_id,tipo,request_id,payload_hash,resultado,metadata_apertura)
 SELECT org_a,sale_a,'apertura',gen_random_uuid(),'fixture-open-a','aplicado',
   '{"cobertura":"historico_auditado"}'::jsonb FROM _fin2c2_f
 UNION ALL
 SELECT org_b,sale_b,'apertura',gen_random_uuid(),'fixture-open-b','aplicado',
   '{"cobertura":"historico_auditado"}'::jsonb FROM _fin2c2_f
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_eventos_financieros(
 organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at)
 SELECT o.organization_id,o.venta_id,o.id,1,'apertura',
        CASE WHEN o.venta_id=-840030001 THEN 100 ELSE 50 END,
        0,now()-interval '1 day'
 FROM ins o;


CREATE TEMP TABLE _refund_fixture(actor_admin uuid,actor_operator uuid,actor_other uuid,
 nc_ok uuid,nc_pending uuid,nc_over uuid,req uuid) ON COMMIT DROP;
INSERT INTO _refund_fixture VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role)
SELECT actor_admin,'authenticated','authenticated' FROM _refund_fixture
UNION ALL SELECT actor_operator,'authenticated','authenticated' FROM _refund_fixture
UNION ALL SELECT actor_other,'authenticated','authenticated' FROM _refund_fixture;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT x.actor_admin,f.org_a,'active','admin' FROM _refund_fixture x CROSS JOIN _fin2c2_f f
UNION ALL SELECT x.actor_operator,f.org_a,'active','operador' FROM _refund_fixture x CROSS JOIN _fin2c2_f f
UNION ALL SELECT x.actor_other,f.org_b,'active','admin' FROM _refund_fixture x CROSS JOIN _fin2c2_f f;
-- Authenticated financial scenarios require a real active employee for each member.
-- Membership-only fixtures must not bypass the 2D-H employment gate.
CREATE TEMP TABLE _refund_branches(organization_id uuid PRIMARY KEY,branch_id uuid NOT NULL) ON COMMIT DROP;
INSERT INTO _refund_branches(organization_id,branch_id)
SELECT org_a,gen_random_uuid() FROM _fin2c2_f
UNION ALL SELECT org_b,gen_random_uuid() FROM _fin2c2_f;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch_id,organization_id,'MAIN','Financial fixture',true,'active' FROM _refund_branches;
INSERT INTO public.empleados(organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT au.organization_id,b.branch_id,au.user_id,au.user_id,
       'Refund fixture employee',au.base_role,true,'active'
FROM public.app_users au
JOIN _refund_branches b ON b.organization_id=au.organization_id
JOIN _refund_fixture f ON au.user_id IN (f.actor_admin,f.actor_operator,f.actor_other);
SET LOCAL session_replication_role=origin;
DO $pay$
DECLARE f _fin2c2_f%ROWTYPE; r jsonb;
BEGIN
 SELECT * INTO f FROM _fin2c2_f;
 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',100,f.payment_at);
 IF (r->>'saldo')::numeric<>0 THEN RAISE EXCEPTION 'Fixture payment failed'; END IF;
END $pay$;
SET LOCAL session_replication_role=replica;
INSERT INTO public.notas_credito(
 id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,
 serie_afectada,correlativo_afectado,motivo_codigo,motivo_descripcion,
 serie,correlativo,fecha_emision,fecha_emision_ts,
 organization_id,moneda,estado,afecta_dinero,total,aceptado_at
)
SELECT items.id,gen_random_uuid(),gen_random_uuid(),f.sale_a,
 'venta','01','F001',1,'01','NC de fixture',
 'FC01',items.n,(now() AT TIME ZONE 'America/Lima')::date,
 now()-interval '10 minutes',f.org_a,'PEN',
 items.status,true,items.amount,items.accepted
FROM _refund_fixture x CROSS JOIN _fin2c2_f f
CROSS JOIN LATERAL (VALUES
 (x.nc_ok,1::bigint,'aceptado'::text,20::numeric,now()-interval '10 minutes'),
 (x.nc_pending,2::bigint,'pendiente_envio'::text,15::numeric,NULL::timestamptz),
 (x.nc_over,3::bigint,'aceptado'::text,150::numeric,now()-interval '10 minutes')
) items(id,n,status,amount,accepted);
SET LOCAL session_replication_role=origin;

CREATE TEMP TABLE _refund_mov_baseline AS
SELECT COUNT(*) AS registros
FROM public.movimientos m CROSS JOIN _fin2c2_f f
WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a;

CREATE TEMP TABLE _refund_results(k text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $scenarios$
DECLARE f _fin2c2_f%ROWTYPE; x _refund_fixture%ROWTYPE; r jsonb; s jsonb;
BEGIN
 SELECT * INTO f FROM _fin2c2_f; SELECT * INTO x FROM _refund_fixture;
 PERFORM set_config('request.jwt.claim.sub',x.actor_admin::text,true);
 r:=private.financial_2c5b_open_refund_case(
 f.org_a,f.sale_a,x.nc_ok,x.req,20,'NC aceptada para revisión administrativa.');
 INSERT INTO _refund_results VALUES ('pending_no_money',
   r->>'estado'='pendiente_conciliacion' AND r->>'dinero_entregado'='false'
   AND r->>'excedente_reservado'='false' AND (r->>'monto_solicitado')::numeric=20);
 s:=private.financial_2c5b_open_refund_case(
 f.org_a,f.sale_a,x.nc_ok,x.req,20,'NC aceptada para revisión administrativa.');
 INSERT INTO _refund_results VALUES('idempotent',s->>'idempotent'='true'
   AND s->>'caso_id'=r->>'caso_id');
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_ok,x.req,19,'NC aceptada para revisión administrativa.');
  INSERT INTO _refund_results VALUES('request_changed',false);
 EXCEPTION WHEN unique_violation THEN INSERT INTO _refund_results VALUES('request_changed',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_ok,gen_random_uuid(),20,'Otra solicitud para la misma NC.');
  INSERT INTO _refund_results VALUES('second_case_same_nc',false);
 EXCEPTION WHEN unique_violation THEN INSERT INTO _refund_results VALUES('second_case_same_nc',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_pending,gen_random_uuid(),10,'NC todavía pendiente SUNAT.');
  INSERT INTO _refund_results VALUES('pending_nc',false);
 EXCEPTION WHEN check_violation THEN INSERT INTO _refund_results VALUES('pending_nc',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),120,'NC supera importe cobrado.');
  INSERT INTO _refund_results VALUES('over_collections',false);
 EXCEPTION WHEN check_violation THEN INSERT INTO _refund_results VALUES('over_collections',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),20.001,'Fracción no permitida de centavo.');
  INSERT INTO _refund_results VALUES('fraction_cent',false);
 EXCEPTION WHEN invalid_parameter_value THEN INSERT INTO _refund_results VALUES('fraction_cent',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),0,'Monto debe ser positivo.');
  INSERT INTO _refund_results VALUES('zero_amount',false);
 EXCEPTION WHEN invalid_parameter_value THEN INSERT INTO _refund_results VALUES('zero_amount',true);
 END;
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),10,'corto');
  INSERT INTO _refund_results VALUES('short_motive',false);
 EXCEPTION WHEN invalid_parameter_value THEN INSERT INTO _refund_results VALUES('short_motive',true);
 END;
 PERFORM set_config('request.jwt.claim.sub',x.actor_operator::text,true);
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),10,'Operador no tiene permiso.');
  INSERT INTO _refund_results VALUES('operator_denied',false);
 EXCEPTION WHEN insufficient_privilege THEN INSERT INTO _refund_results VALUES('operator_denied',true);
 END;
 PERFORM set_config('request.jwt.claim.sub',x.actor_other::text,true);
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),10,'Admin de otra organización.');
  INSERT INTO _refund_results VALUES('cross_tenant_denied',false);
 EXCEPTION WHEN insufficient_privilege THEN INSERT INTO _refund_results VALUES('cross_tenant_denied',true);
 END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN
  PERFORM private.financial_2c5b_open_refund_case(
   f.org_a,f.sale_a,x.nc_over,gen_random_uuid(),10,'Sin token de autenticación.');
  INSERT INTO _refund_results VALUES('jwt_required',false);
 EXCEPTION WHEN invalid_parameter_value THEN INSERT INTO _refund_results VALUES('jwt_required',true);
 END;
END $scenarios$;
DO $assert$
BEGIN
 IF EXISTS(SELECT 1 FROM _refund_results WHERE NOT passed) THEN
  RAISE EXCEPTION '2C5B case failures: %',
    (SELECT string_agg(k,', ' ORDER BY k) FROM _refund_results WHERE NOT passed);
 END IF;
END $assert$;
SELECT plan(23);
SELECT ok(((SELECT passed FROM _refund_results WHERE k='pending_no_money')), 'pending_no_money');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='idempotent')), 'idempotent');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='request_changed')), 'request_changed');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='second_case_same_nc')), 'second_case_same_nc');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='pending_nc')), 'pending_nc');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='over_collections')), 'over_collections');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='fraction_cent')), 'fraction_cent');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='zero_amount')), 'zero_amount');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='short_motive')), 'short_motive');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='operator_denied')), 'operator_denied');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='cross_tenant_denied')), 'cross_tenant_denied');
SELECT ok(((SELECT passed FROM _refund_results WHERE k='jwt_required')), 'jwt_required');
SELECT ok(((SELECT count(*)=1 FROM private.venta_solicitudes_devolucion)), 'one_case_only');
SELECT ok((EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='private.venta_solicitudes_devolucion'::regclass AND tgname='devolucion_2c5b_immutable')), 'immutable_trigger');
SELECT ok((NOT has_table_privilege('authenticated','private.venta_solicitudes_devolucion','SELECT') AND NOT has_table_privilege('service_role','private.venta_solicitudes_devolucion','INSERT')), 'strict_acl');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c5b_open_refund_case(uuid,bigint,uuid,uuid,numeric,text)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c5b_open_refund_case(uuid,bigint,uuid,uuid,numeric,text)','EXECUTE')), 'private_function');
SELECT ok(((SELECT relrowsecurity FROM pg_class WHERE oid='private.venta_solicitudes_devolucion'::regclass)), 'rls_enabled');
SELECT ok(((SELECT count(*)=0 FROM public.venta_eventos_financieros WHERE tipo='devolucion')), 'no_refund_events');
SELECT ok(((SELECT COUNT(*)=(SELECT registros FROM _refund_mov_baseline) FROM public.movimientos m CROSS JOIN _fin2c2_f f WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a)), 'no_refund_cash_movement');
SELECT ok(((SELECT exigible=100 AND cobros_netos=100 AND saldo_pendiente=0 AND excedente=0 FROM public.venta_cuentas_financieras cf JOIN _fin2c2_f f ON cf.organization_id=f.org_a AND cf.venta_id=f.sale_a)), 'balance_unchanged');
SELECT ok(((SELECT count(*)=1 AND SUM(monto)=100 FROM public.pagos_venta p JOIN _fin2c2_f f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a)), 'payment_unchanged');
SELECT ok(((SELECT count(*)=0 FROM private.venta_solicitudes_devolucion c JOIN _fin2c2_f f ON c.organization_id=f.org_b AND c.venta_id=f.sale_b)), 'other_company_no_case');
SELECT ok(((SELECT count(*)=0 FROM private.financial_2c2_write_intents)), 'no_leaked_intents');
SELECT * FROM finish();
ROLLBACK;
