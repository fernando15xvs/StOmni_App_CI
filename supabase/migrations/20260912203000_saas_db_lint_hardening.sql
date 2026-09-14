-- Cierre de laboratorio: corrige errores reales detectados por `supabase db lint`
-- y evita que plpgsql_check evalúe guards de contexto como constantes durante
-- el análisis estático. No relaja ninguna autorización ni aislamiento tenant.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Los helpers `require_*` dependen del contexto de sesión/request y pueden
--    lanzar excepciones deliberadamente. Marcarlos VOLATILE evita que el planner
--    o el linter intenten preevaluarlos sin un contexto autenticado/verificado.
-- -----------------------------------------------------------------------------
ALTER FUNCTION private.require_current_organization_id() VOLATILE;
ALTER FUNCTION private.require_service_organization_id() VOLATILE;

-- -----------------------------------------------------------------------------
-- 2. Existe un overload legacy (bigint) y F3.6 añadió
--    (bigint,boolean DEFAULT false). El DEFAULT hace que una llamada de un
--    argumento coincida con ambas firmas. La firma extendida es un superset y
--    con DEFAULT false conserva la semántica legacy, por lo cual retiramos sólo
--    el overload obsoleto. No usar CASCADE: una dependencia real debe fallar
--    explícitamente en el laboratorio.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.assert_supplier_in_current_organization(bigint);

-- -----------------------------------------------------------------------------
-- 3. El writer de bundles no necesita una tabla temporal. Se valida el payload
--    con las mismas reglas y luego se conserva la semántica histórica de
--    deduplicación: si un producto aparece varias veces, gana la última entrada.
--    Esto deja el SQL completamente verificable por plpgsql_check.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_bundle_components_v1(
  p_bundle_product_id bigint,
  p_components jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row jsonb;
  v_component_id bigint;
  v_quantity numeric;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant administrator permission required';
  END IF;
  IF p_components IS NULL OR jsonb_typeof(p_components)<>'array' OR jsonb_array_length(p_components)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Bundle requires at least one component';
  END IF;

  PERFORM 1
  FROM public.productos p
  WHERE p.organization_id=v_org
    AND p.id=p_bundle_product_id
    AND p.item_type='bundle'
    AND COALESCE(p.activo,true)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Bundle not available in current organization';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_components)
  LOOP
    IF jsonb_typeof(v_row)<>'object' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid bundle component';
    END IF;
    v_component_id:=NULLIF(v_row->>'product_id','')::bigint;
    v_quantity:=NULLIF(v_row->>'quantity','')::numeric;
    IF v_component_id IS NULL OR v_quantity IS NULL OR v_quantity<=0 OR v_quantity>1000000000 THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid bundle component quantity';
    END IF;
  END LOOP;

  DELETE FROM public.bundle_components
  WHERE organization_id=v_org AND bundle_product_id=p_bundle_product_id;

  WITH parsed AS (
    SELECT
      (e.value->>'product_id')::bigint AS component_product_id,
      (e.value->>'quantity')::numeric AS quantity,
      e.ordinality
    FROM jsonb_array_elements(p_components) WITH ORDINALITY AS e(value, ordinality)
  ), deduplicated AS (
    SELECT DISTINCT ON (component_product_id)
      component_product_id,
      quantity
    FROM parsed
    ORDER BY component_product_id, ordinality DESC
  )
  INSERT INTO public.bundle_components(
    organization_id,bundle_product_id,component_product_id,quantity
  )
  SELECT v_org,p_bundle_product_id,d.component_product_id,d.quantity
  FROM deduplicated d;

  RETURN public.get_bundle_components_v1(p_bundle_product_id);
END;
$$;
REVOKE ALL ON FUNCTION public.set_bundle_components_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_bundle_components_v1(bigint,jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. F6.3 referenciaba una columna inexistente `ventas.descuento`. El campo
--    autoritativo usado por ventas/reportes es `descuento_global_monto`.
--    Se parchea la definición final para conservar los guards añadidos después
--    (por ejemplo, subscription feature.analytics).
-- -----------------------------------------------------------------------------
DO $dashboard_discount_patch$
DECLARE
  v_sig regprocedure := 'public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure;
  v_def text;
  v_old text := 'coalesce(sum(v.descuento),0)';
  v_new text := 'coalesce(sum(v.descuento_global_monto),0)';
  v_matches integer;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_matches := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
  IF v_matches<>1 THEN
    RAISE EXCEPTION 'Unexpected dashboard discount contract: expected 1 legacy expression, found %',v_matches;
  END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$dashboard_discount_patch$;

-- -----------------------------------------------------------------------------
-- 5. F4.3 reemplazó la idempotencia global de pagos de deuda por la clave
--    tenant-aware (organization_id, request_id). La copia legacy conservaba
--    `ON CONFLICT (request_id)`, que ya no corresponde a ningún constraint y
--    hace fallar plpgsql_check. La RPC pública vigente ya implementa el flujo
--    tenant-aware, por lo que retiramos únicamente la copia legacy obsoleta.
--    No usar CASCADE: cualquier dependencia real debe fallar explícitamente.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public._legacy_procesar_pago_deuda_v2(
  uuid,
  boolean,
  bigint,
  numeric,
  text,
  timestamptz,
  boolean
);

COMMIT;
