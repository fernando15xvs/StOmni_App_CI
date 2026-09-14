-- Fase 3.6 SaaS: idempotencia tenant-local y defensa polimórfica de pagos de deuda.
BEGIN;

-- Dos tenants pueden generar el mismo UUID: la autoridad de idempotencia es
-- (organization_id, request_id), no la existencia del UUID en otra empresa.
CREATE OR REPLACE FUNCTION private.assert_purchase_payload_in_current_organization(
  p_request_id uuid,
  p_supplier_id bigint,
  p_warehouse_id bigint,
  p_lines jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_line jsonb;
  v_product_id bigint;
BEGIN
  PERFORM private.require_current_organization_id();
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id is required';
  END IF;

  PERFORM private.assert_supplier_in_current_organization(p_supplier_id,true);
  PERFORM private.assert_warehouse_in_current_organization(p_warehouse_id);

  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Purchase lines must be a non-empty array';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    IF jsonb_typeof(v_line)<>'object' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid purchase line';
    END IF;
    v_product_id:=NULLIF(v_line->>'product_id','')::bigint;
    PERFORM private.assert_product_in_current_organization(v_product_id);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION private.assert_purchase_payload_in_current_organization(uuid,bigint,bigint,jsonb)
  FROM PUBLIC,anon,authenticated;

-- La versión creada en la migración anterior incluía un precheck global de UUID.
-- Se retira de forma determinista antes de cualquier ejecución de la aplicación.
-- pg_get_functiondef() conserva los saltos de línea del cuerpo PL/pgSQL. Por eso
-- aceptamos tanto LF como CRLF: el checkout en Windows no debe cambiar la semántica
-- ni hacer fallar esta migración por una diferencia meramente de formato.
DO $patch_receipt_request_scope$
DECLARE
  v_sig regprocedure := 'public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)'::regprocedure;
  v_def text;
  v_old_lf text;
  v_old_crlf text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old_lf:=E'  IF EXISTS (\n    SELECT 1 FROM public.purchase_receipts\n    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org\n  ) THEN\n    RAISE EXCEPTION ''El request_id pertenece a otra organización'' USING ERRCODE=''23505'';\n  END IF;\n\n';
  v_old_crlf:=replace(v_old_lf,E'\n',E'\r\n');

  IF strpos(v_def,v_old_lf)>0 THEN
    v_def:=replace(v_def,v_old_lf,'');
  ELSIF strpos(v_def,v_old_crlf)>0 THEN
    v_def:=replace(v_def,v_old_crlf,'');
  ELSE
    RAISE EXCEPTION 'F3.6 request-scope patch mismatch: purchase receipt global UUID check';
  END IF;

  EXECUTE v_def;
END;
$patch_receipt_request_scope$;

-- pagos_deuda_requests.deuda_id es polimórfico (venta o gasto), por lo que no
-- admite una FK declarativa única. Este trigger aplica la misma garantía.
CREATE OR REPLACE FUNCTION private.enforce_debt_request_target_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.organization_id IS NULL OR NEW.deuda_id IS NULL OR NEW.es_cliente IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='23502', MESSAGE='Debt request requires tenant, target and type';
  END IF;

  IF NEW.es_cliente THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.ventas
      WHERE organization_id=NEW.organization_id AND id=NEW.deuda_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Debt target not available in organization';
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.gastos
      WHERE organization_id=NEW.organization_id AND id=NEW.deuda_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Debt target not available in organization';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_debt_request_target_tenant()
  FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS pagos_deuda_requests_validate_target_tenant ON public.pagos_deuda_requests;
CREATE TRIGGER pagos_deuda_requests_validate_target_tenant
AFTER INSERT OR UPDATE OF organization_id,es_cliente,deuda_id
ON public.pagos_deuda_requests
FOR EACH ROW EXECUTE FUNCTION private.enforce_debt_request_target_tenant();

-- Validar también cualquier request legacy backfilleado antes de activar el trigger.
DO $validate_existing_debt_targets$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.pagos_deuda_requests AS r
    LEFT JOIN public.ventas AS v
      ON r.es_cliente
     AND v.organization_id=r.organization_id
     AND v.id=r.deuda_id
    LEFT JOIN public.gastos AS g
      ON NOT r.es_cliente
     AND g.organization_id=r.organization_id
     AND g.id=r.deuda_id
    WHERE (r.es_cliente AND v.id IS NULL)
       OR (NOT r.es_cliente AND g.id IS NULL)
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Legacy debt request points outside its organization';
  END IF;
END;
$validate_existing_debt_targets$;

COMMIT;
