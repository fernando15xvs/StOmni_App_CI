-- 2D-E catalog natural keys are tenant-local, never global.
-- Genuine constraint checks; no fixture survives BEGIN/ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(10);
CREATE TEMP TABLE _2de_product_fixture(org_a uuid,org_b uuid) ON COMMIT DROP;
INSERT INTO _2de_product_fixture VALUES(gen_random_uuid(),gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2D-E test catalog A','PE','PEN','America/Lima' FROM _2de_product_fixture
UNION ALL SELECT org_b,'2D-E test catalog B','PE','PEN','America/Lima' FROM _2de_product_fixture;
CREATE FUNCTION pg_temp.insert_product(p_id bigint,p_org uuid,p_name text,p_code text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
 INSERT INTO public.productos(
  id,organization_id,nombre,codigo,precio_unidad,precio_caja,
  tipo_venta,permitir_sin_stock,activo,es_servicio,item_type)
 VALUES(p_id,p_org,p_name,p_code,100,100,'UNIDAD',false,true,false,'stock_product');
END $fn$;
CREATE FUNCTION pg_temp.unique_rejected(p_id bigint,p_org uuid,p_name text,p_code text)
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM pg_temp.insert_product(p_id,p_org,p_name,p_code);
 RETURN false;
EXCEPTION WHEN unique_violation THEN RETURN true;
END $fn$;
SELECT pg_temp.insert_product(-840150001,org_a,'producto compartido','SKU-EMPRESA') FROM _2de_product_fixture;
SELECT pg_temp.insert_product(-840150002,org_b,'producto compartido','SKU-EMPRESA') FROM _2de_product_fixture;
SELECT ok((SELECT count(*)=2 FROM public.productos p
 JOIN _2de_product_fixture f ON p.organization_id IN(f.org_a,f.org_b)
 WHERE p.nombre='producto compartido' AND p.codigo='SKU-EMPRESA'),
 'distinct organizations can use same normalized name and SKU');
SELECT ok((SELECT count(*)=2 FROM public.productos p
 JOIN _2de_product_fixture f ON p.organization_id IN(f.org_a,f.org_b)
 WHERE lower(btrim(p.nombre))='producto compartido'),
 'two tenant product fixtures persisted in test transaction');
SELECT ok((SELECT pg_temp.unique_rejected(-840150003,org_a,'producto compartido','SKU-OTHER')
 FROM _2de_product_fixture),
 'same org cannot reuse name even with different SKU');
SELECT ok((SELECT pg_temp.unique_rejected(-840150004,org_a,'PRODUCTO COMPARTIDO ','SKU-DIFF')
 FROM _2de_product_fixture),
 'same org name uniqueness case/whitespace insensitive');
SELECT ok((SELECT pg_temp.unique_rejected(-840150005,org_a,'producto alternativo','SKU-EMPRESA')
 FROM _2de_product_fixture),
 'same org cannot reuse exact SKU with different name');
SELECT ok((SELECT pg_temp.unique_rejected(-840150006,org_a,'producto tercero',' sku-empresa ')
 FROM _2de_product_fixture),
 'same org SKU uniqueness case/whitespace insensitive');
SELECT pg_temp.insert_product(-840150007,org_a,'unico nuevo','SKU-NEW') FROM _2de_product_fixture;
SELECT ok((SELECT count(*)=2 FROM public.productos p JOIN _2de_product_fixture f ON p.organization_id=f.org_a
 WHERE p.id IN(-840150001,-840150007)),
 'distinct names and codes remain allowed in one org');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='productos'
 AND indexname='idx_producto_unico' AND indexdef LIKE '%organization_id%'),
 'product natural-name unique index is tenant scoped');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='productos'
 AND indexname='productos_codigo_unique'),
 'unsafe global SKU uniqueness index removed');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='productos'
 AND indexname='productos_organization_code_key' AND indexdef LIKE '%UNIQUE%'),
 'tenant scoped normalized SKU index retained');
SELECT * FROM finish();
ROLLBACK;
