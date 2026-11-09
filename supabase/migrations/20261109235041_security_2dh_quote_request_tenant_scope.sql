-- 2D-H: prevent cross-tenant replay of quotation request_id.
-- Previous sales request guard did not check public.cotizaciones, while the
-- quotation legacy writers look up idempotency globally and exposed quote IDs.
-- Preserve the existing SQLSTATE 23505 collision contract.
CREATE OR REPLACE FUNCTION private.assert_sales_request_scope(p_request_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id is required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ventas
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) OR EXISTS (
    SELECT 1 FROM public.ventas_requests_anulados
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) OR EXISTS (
    SELECT 1 FROM public.pagos_deuda_requests
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) OR EXISTS (
    -- Quote writers also perform idempotency lookup globally by request_id.
    -- Reject a foreign tenant before any legacy writer can reveal its quote.
    SELECT 1 FROM public.cotizaciones
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23505', MESSAGE='request_id belongs to another organization';
  END IF;
END;
$function$;
