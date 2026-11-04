-- 2D-A strict validation, grant and fail-closed contract. All objects are reversible.
BEGIN;
CREATE TEMP TABLE _credit_checks (label text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.credit_ok(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '2D credit failed: %',label; END IF;
 INSERT INTO _credit_checks VALUES(label);
END $$;
CREATE FUNCTION pg_temp.credit_fails(test_sql text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN EXECUTE test_sql; RETURN false; EXCEPTION WHEN OTHERS THEN RETURN true; END $$;
CREATE FUNCTION pg_temp.credit_validate(
 terms jsonb DEFAULT '[{"number":1,"amount":400,"due_date":"2025-02-01"},{"number":2,"amount":400,"due_date":"2025-03-01"}]'::jsonb,
 total numeric DEFAULT 1000,
 down_payment numeric DEFAULT 200,
 payments jsonb DEFAULT '[{"metodo":"transferencia","monto":200}]'::jsonb,
 sale_at timestamptz DEFAULT '2025-01-01 12:00:00-05'::timestamptz
) RETURNS numeric LANGUAGE sql AS $$
 SELECT private.financial_2d_validate_terms(sale_at,total,down_payment,payments,terms)
$$;
SELECT pg_temp.credit_ok(pg_temp.credit_validate()=800,'two future installments reconcile in exact cents');
SELECT pg_temp.credit_ok(pg_temp.credit_validate(
 '[{"number":1,"amount":1000,"due_date":"2025-02-01"}]',1000,0,'[]')=1000,
 'zero down-payment with one installment is valid');
SELECT pg_temp.credit_ok(pg_temp.credit_validate(
 '[{"number":1,"amount":400,"due_date":"2025-02-01"},{"number":2,"amount":400,"due_date":"2025-02-01"}]')=800,
 'same-day installments are allowed');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":399.99,"due_date":"2025-02-01"},{"number":2,"amount":400,"due_date":"2025-03-01"}]')$q$),'one-cent shortfall rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":400.01,"due_date":"2025-02-01"},{"number":2,"amount":400,"due_date":"2025-03-01"}]')$q$),'one-cent overage rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":400.001,"due_date":"2025-02-01"},{"number":2,"amount":399.999,"due_date":"2025-03-01"}]')$q$),'fractional cents rejected even if sum matches');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[]')$q$),'empty installment plan rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":2,"amount":800,"due_date":"2025-02-01"}]')$q$),'non-sequential numbers rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":400,"due_date":"2025-03-01"},{"number":2,"amount":400,"due_date":"2025-02-01"}]')$q$),'decreasing due dates rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":800,"due_date":"2025-01-01"}]')$q$),'due date equal to sale date rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":800,"due_date":"2025-02-30"}]')$q$),'invalid date rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate('[{"number":1,"amount":800,"due_date":"2025/02/01"}]')$q$),'non ISO due date rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(null)$q$),'null terms rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(
 '[{"number":1,"amount":800,"due_date":"2025-02-01"}]',1000,200,'[{"metodo":"efectivo","monto":200}]')$q$),'unreconciled initial cash payment blocked');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(
 '[{"number":1,"amount":800,"due_date":"2025-02-01"}]',1000,200,'[{"metodo":"transferencia","monto":199.99}]')$q$),'one-cent payment mismatch rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(
 '[{"number":1,"amount":800,"due_date":"2025-02-01"}]',1000,200.001)$q$),'fractional down-payment rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(
 '[{"number":1,"amount":800,"due_date":"2025-02-01"}]',1000.001,200)$q$),'fractional sale total rejected');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT pg_temp.credit_validate(
 '[{"number":1,"amount":800,"due_date":"2025-02-01"}]',1000,200.01)$q$),'off-by-cent down-payment rejected');
SELECT pg_temp.credit_ok(NOT has_function_privilege('anon','public.process_sale_credit_v5(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)','EXECUTE'),'anon lacks credit RPC execute');
SELECT pg_temp.credit_ok(has_function_privilege('authenticated','public.process_sale_credit_v5(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)','EXECUTE'),'authenticated seller may invoke gated RPC');
SELECT pg_temp.credit_ok(NOT has_function_privilege('authenticated','private.financial_2d_validate_terms(timestamptz,numeric,numeric,jsonb,jsonb)','EXECUTE'),'preflight remains private');
SELECT pg_temp.credit_ok(pg_temp.credit_fails($q$SELECT public.process_sale_credit_v5(
 gen_random_uuid(),NULL,1000,now(),true,200,'[]','[{"metodo":"transferencia","monto":200}]',
 NULL,NULL,'ticket_interno',0,0,NULL,1000,NULL,
 '[{"number":1,"amount":800,"due_date":"2030-02-01"}]')$q$),'no authenticated actor cannot create credit sale');
SELECT pg_temp.credit_ok((SELECT count(*)=0 FROM private.refund_write_intents),'credit preflight does not enqueue refund intents');
SELECT '1..'||count(*) FROM _credit_checks;
SELECT 'ok '||row_number() OVER(ORDER BY label)||' - '||label FROM _credit_checks;
ROLLBACK;
