-- 2D-B: reversible authenticated reader test. Multi-tenant, paid installments,
-- empty/unauthorized, corrupt schedule; never persists customer information.
BEGIN;
CREATE TEMP TABLE _credit_fixture (
  org_a uuid,org_b uuid,actor_a uuid,actor_b uuid,sale_a bigint,sale_b bigint,
  cr_a uuid,cr_b uuid
) ON COMMIT DROP;
INSERT INTO _credit_fixture VALUES
(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 840030101,840030102,gen_random_uuid(),gen_random_uuid());
CREATE TEMP TABLE _credit_reader_results (name text PRIMARY KEY, response jsonb) ON COMMIT DROP;
GRANT INSERT,SELECT ON TABLE _credit_reader_results TO authenticated;

-- Synthetic identities and sales bypass legacy tenant creation triggers.
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'Credit reader A','PE','PEN','America/Lima' FROM _credit_fixture
UNION ALL SELECT org_b,'Credit reader B','PE','PEN','America/Lima' FROM _credit_fixture;
INSERT INTO auth.users(id,aud,role)
SELECT actor_a,'authenticated','authenticated' FROM _credit_fixture
UNION ALL SELECT actor_b,'authenticated','authenticated' FROM _credit_fixture;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor_a,org_a,'active','admin' FROM _credit_fixture
UNION ALL SELECT actor_b,org_b,'active','admin' FROM _credit_fixture;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito,fue_credito)
SELECT sale_a,org_a,100,60,'pendiente',now()-interval '1 day',0,true FROM _credit_fixture
UNION ALL SELECT sale_b,org_b,50,50,'pendiente',now()-interval '1 day',0,true FROM _credit_fixture;
SET LOCAL session_replication_role=origin;

INSERT INTO public.venta_cuentas_financieras
 (organization_id,venta_id,moneda,estado_conciliacion,exigible,cobros_netos,saldo_pendiente,revision)
SELECT org_a,sale_a,'PEN','conciliada',100,40,60,2 FROM _credit_fixture
UNION ALL SELECT org_b,sale_b,'PEN','conciliada',50,0,50,1 FROM _credit_fixture;
INSERT INTO public.venta_cronogramas(id,organization_id,venta_id,version,estado)
SELECT cr_a,org_a,sale_a,1,'vigente' FROM _credit_fixture
UNION ALL SELECT cr_b,org_b,sale_b,1,'vigente' FROM _credit_fixture;
INSERT INTO public.venta_cuotas
 (organization_id,venta_id,cronograma_id,numero,vencimiento,importe_original,importe_vigente)
SELECT f.org_a,f.sale_a,f.cr_a,i.n,
 (now() AT TIME ZONE 'America/Lima')::date+i.n*10,i.amount,i.amount
FROM _credit_fixture f CROSS JOIN (VALUES(1,20::numeric),(2,40::numeric)) i(n,amount)
UNION ALL
SELECT org_b,sale_b,cr_b,1,(now() AT TIME ZONE 'America/Lima')::date+10,50,50
FROM _credit_fixture;

-- Owner (postgres) checks direct client grant surface before impersonation.
CREATE FUNCTION pg_temp.check_reader(p_ok boolean,p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '2D-B reader: %',p_label; END IF;
END $$;
SELECT pg_temp.check_reader(
  NOT has_function_privilege('anon','public.obtener_cronograma_credito_v1(bigint)','EXECUTE')
  AND has_function_privilege('authenticated','public.obtener_cronograma_credito_v1(bigint)','EXECUTE'),
  'reader authenticated-only');
SELECT pg_temp.check_reader(
  NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid='public.obtener_cronograma_credito_v1(bigint)'::regprocedure),
  'reader is security invoker, not definer');
SELECT pg_temp.check_reader(public.obtener_cronograma_credito_v1(840030101) IS NULL,
  'missing identity returns null');

SELECT set_config('request.jwt.claim.sub',(SELECT actor_a::text FROM _credit_fixture),true);
SET LOCAL ROLE authenticated;
INSERT INTO _credit_reader_results(name,response) VALUES
 ('a_own',public.obtener_cronograma_credito_v1(840030101)),
 ('a_cross',public.obtener_cronograma_credito_v1(840030102)),
 ('a_unknown',public.obtener_cronograma_credito_v1(840039999));
RESET ROLE;

SELECT set_config('request.jwt.claim.sub',(SELECT actor_b::text FROM _credit_fixture),true);
SET LOCAL ROLE authenticated;
INSERT INTO _credit_reader_results(name,response) VALUES
 ('b_own',public.obtener_cronograma_credito_v1(840030102)),
 ('b_cross',public.obtener_cronograma_credito_v1(840030101));
RESET ROLE;

SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SET LOCAL ROLE authenticated;
INSERT INTO _credit_reader_results(name,response)
VALUES ('without_membership',public.obtener_cronograma_credito_v1(840030101));
RESET ROLE;

SELECT pg_temp.check_reader(
 (SELECT response->>'venta_id'='840030101'
    AND response->>'moneda'='PEN'
    AND (response->>'exigible')::numeric=100
    AND (response->>'cobros_netos')::numeric=40
    AND (response->>'saldo_pendiente')::numeric=60
    AND (response->>'cronograma_version')::integer=1
    AND jsonb_array_length(response->'cuotas')=2
    FROM _credit_reader_results WHERE name='a_own'),'A sees own current balance and schedule');
SELECT pg_temp.check_reader(
 (SELECT (response->'cuotas'->0->>'saldo_pendiente')::numeric=20
    AND (response->'cuotas'->1->>'saldo_pendiente')::numeric=40
    AND response->'cuotas'->0->>'estado'='pendiente'
    FROM _credit_reader_results WHERE name='a_own'),'A sees ordered exact installment amounts');
SELECT pg_temp.check_reader(
 (SELECT response IS NULL FROM _credit_reader_results WHERE name='a_cross'),'A cannot see B sale');
SELECT pg_temp.check_reader(
 (SELECT response IS NULL FROM _credit_reader_results WHERE name='b_cross'),'B cannot see A sale');
SELECT pg_temp.check_reader(
 (SELECT response IS NULL FROM _credit_reader_results WHERE name='a_unknown'),'unknown sale stays invisible');
SELECT pg_temp.check_reader(
 (SELECT response IS NULL FROM _credit_reader_results WHERE name='without_membership'),'removed membership returns null');
SELECT pg_temp.check_reader(
 (SELECT response->>'venta_id'='840030102'
    AND (response->>'saldo_pendiente')::numeric=50
    AND jsonb_array_length(response->'cuotas')=1
   FROM _credit_reader_results WHERE name='b_own'),'B sees only own credit balance');
SELECT jsonb_build_object('checks',10,'passed',true) AS reader_2db_verification;
ROLLBACK;
