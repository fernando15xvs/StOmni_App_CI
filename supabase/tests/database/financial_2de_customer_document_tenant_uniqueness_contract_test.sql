-- 2D-E: two independent organizations may sell to the same natural person.
-- Exact document uniqueness remains enforced within each tenant only.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(7);
CREATE TEMP TABLE _2de_customer_fixture(org_a uuid,org_b uuid) ON COMMIT DROP;
INSERT INTO _2de_customer_fixture VALUES(gen_random_uuid(),gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2D-E customer org A','PE','PEN','America/Lima' FROM _2de_customer_fixture
UNION ALL SELECT org_b,'2D-E customer org B','PE','PEN','America/Lima' FROM _2de_customer_fixture;
CREATE FUNCTION pg_temp.new_client(p_id bigint,p_org uuid,p_name text,p_document text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
 INSERT INTO public.clientes(id,organization_id,nombre,dni_ruc)
 VALUES(p_id,p_org,p_name,p_document);
END $fn$;
CREATE FUNCTION pg_temp.client_duplicate_rejected(p_id bigint,p_org uuid,p_doc text)
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM pg_temp.new_client(p_id,p_org,'Client duplicate',p_doc);
 RETURN false;
EXCEPTION WHEN unique_violation THEN RETURN true;
END $fn$;
CREATE FUNCTION pg_temp.client_bad_format_rejected(p_id bigint,p_org uuid,p_doc text)
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM pg_temp.new_client(p_id,p_org,'Invalid format client',p_doc);
 RETURN false;
EXCEPTION WHEN check_violation THEN RETURN true;
END $fn$;
SELECT pg_temp.new_client(-840151001,org_a,'Shared customer','99988877') FROM _2de_customer_fixture;
SELECT pg_temp.new_client(-840151002,org_b,'Same person across tenant','99988877') FROM _2de_customer_fixture;
SELECT ok((SELECT count(*)=2 FROM public.clientes c CROSS JOIN _2de_customer_fixture f
 WHERE c.organization_id IN(f.org_a,f.org_b) AND c.dni_ruc='99988877'),
 'different companies can independently register same customer DNI');
SELECT ok((SELECT pg_temp.client_duplicate_rejected(-840151003,org_a,'99988877') FROM _2de_customer_fixture),
 'within tenant duplicate DNI/RUC is rejected');
SELECT ok((SELECT pg_temp.client_bad_format_rejected(-840151004,org_a,' 99988877 ') FROM _2de_customer_fixture),
 'document with surrounding whitespace is rejected by formatting check');
SELECT pg_temp.new_client(-840151005,org_a,'Another person','88887777') FROM _2de_customer_fixture;
SELECT ok((SELECT count(*)=2 FROM public.clientes c CROSS JOIN _2de_customer_fixture f
 WHERE c.organization_id=f.org_a AND c.id IN(-840151001,-840151005)),
 'distinct documents remain permitted in same tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public'
 AND tablename='clientes' AND indexname='clientes_organization_document_key'
 AND indexdef LIKE '%UNIQUE%'),'existing per-org normalized document key stays unique');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public'
 AND tablename='clientes' AND indexname='clientes_dni_ruc_unique'),
 'global DNI/RUC unique index removed');
SELECT ok((SELECT count(DISTINCT c.organization_id)=2 FROM public.clientes c
 CROSS JOIN _2de_customer_fixture f WHERE c.organization_id IN(f.org_a,f.org_b)
 AND c.dni_ruc='99988877'),'tenant ownership preserved for same document');
SELECT * FROM finish();
ROLLBACK;
