-- Fase 3.5 SaaS: endurecimiento tenant-aware de ventas, cotizaciones y cobros a clientes.
-- La facturación electrónica se reabre en F3.7 después de tenantificar series/comprobantes.
-- La rama de pagos a proveedor se reabre en F3.6; caja en efectivo depende de F4.3.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Constancias de descuento: parte del dominio de ventas, no del emisor fiscal.
-- -----------------------------------------------------------------------------
ALTER TABLE public.constancias_descuento ADD COLUMN organization_id uuid;

UPDATE public.constancias_descuento AS c
SET organization_id = v.organization_id
FROM public.ventas AS v
WHERE c.organization_id IS NULL
  AND c.venta_id = v.id;

DO $constancias_backfill$
DECLARE
  v_count integer;
  v_org uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.constancias_descuento WHERE organization_id IS NULL) THEN
    SELECT count(DISTINCT organization_id)::integer
    INTO v_count
    FROM public.configuracion_negocio;

    IF v_count <> 1 THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Ambiguous legacy discount certificates require exactly one organization';
    END IF;

    SELECT organization_id INTO v_org
    FROM public.configuracion_negocio
    ORDER BY organization_id::text
    LIMIT 1;

    UPDATE public.constancias_descuento
    SET organization_id=v_org
    WHERE organization_id IS NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.constancias_descuento c
    JOIN public.ventas v ON v.id=c.venta_id
    WHERE c.organization_id IS DISTINCT FROM v.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant discount certificate exists';
  END IF;
END;
$constancias_backfill$;

ALTER TABLE public.constancias_descuento ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.constancias_descuento
  ADD CONSTRAINT constancias_descuento_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;

ALTER TABLE public.constancias_descuento
  DROP CONSTRAINT IF EXISTS constancias_descuento_venta_id_fkey,
  DROP CONSTRAINT IF EXISTS constancias_descuento_aplicado_por_fkey,
  DROP CONSTRAINT IF EXISTS constancias_descuento_autorizado_por_fkey,
  DROP CONSTRAINT IF EXISTS constancias_descuento_codigo_key;

ALTER TABLE public.constancias_descuento
  ADD CONSTRAINT constancias_descuento_venta_id_fkey
    FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id),
  ADD CONSTRAINT constancias_descuento_aplicado_por_fkey
    FOREIGN KEY (organization_id,aplicado_por) REFERENCES public.empleados(organization_id,id),
  ADD CONSTRAINT constancias_descuento_autorizado_por_fkey
    FOREIGN KEY (organization_id,autorizado_por) REFERENCES public.empleados(organization_id,id) ON DELETE SET NULL (autorizado_por);

CREATE UNIQUE INDEX constancias_descuento_organization_codigo_key
  ON public.constancias_descuento(organization_id,codigo);
CREATE INDEX constancias_descuento_organization_id_idx
  ON public.constancias_descuento(organization_id);

CREATE TRIGGER constancias_descuento_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.constancias_descuento
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();

ALTER TABLE public.constancias_descuento ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS constancias_descuento_select ON public.constancias_descuento;
CREATE POLICY constancias_descuento_tenant_select ON public.constancias_descuento
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
REVOKE ALL ON TABLE public.constancias_descuento FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.constancias_descuento TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Assertions privadas reutilizables por RPC SECURITY DEFINER.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.assert_customer_in_current_organization(p_customer_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_customer_id IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.clientes
    WHERE organization_id=v_org AND id=p_customer_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Customer not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_quotation_in_current_organization(p_quote_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_quote_id IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.cotizaciones
    WHERE organization_id=v_org AND id=p_quote_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Quotation not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_sale_in_current_organization(p_sale_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_sale_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.ventas
    WHERE organization_id=v_org AND id=p_sale_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Sale not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_sale_payment_in_current_organization(p_payment_id bigint,p_sale_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_payment_id IS NULL OR p_sale_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pagos_venta
    WHERE organization_id=v_org AND id=p_payment_id AND venta_id=p_sale_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Sale payment not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_sales_request_scope(p_request_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
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
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23505', MESSAGE='request_id belongs to another organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_sales_payload_in_current_organization(
  p_request_id uuid,
  p_customer_id bigint,
  p_quote_id bigint,
  p_details jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_detail jsonb;
  v_product_id bigint;
  v_warehouse_id bigint;
BEGIN
  PERFORM private.require_current_organization_id();
  PERFORM private.assert_sales_request_scope(p_request_id);
  PERFORM private.assert_customer_in_current_organization(p_customer_id);
  PERFORM private.assert_quotation_in_current_organization(p_quote_id);

  IF p_details IS NULL OR jsonb_typeof(p_details)<>'array' OR jsonb_array_length(p_details)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Sale/quotation details must be a non-empty array';
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_details)
  LOOP
    IF jsonb_typeof(v_detail)<>'object' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid sale/quotation detail';
    END IF;
    v_product_id:=NULLIF(v_detail->>'producto_id','')::bigint;
    v_warehouse_id:=NULLIF(v_detail->>'almacen_id','')::bigint;
    PERFORM private.assert_product_in_current_organization(v_product_id);
    PERFORM private.assert_warehouse_in_current_organization(v_warehouse_id);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_customer_in_current_organization(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_quotation_in_current_organization(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_sale_in_current_organization(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_sale_payment_in_current_organization(bigint,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_sales_request_scope(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_sales_payload_in_current_organization(uuid,bigint,bigint,jsonb) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 3. Parche determinista al motor autoritativo process_sale_v3.
--    Se preserva su lógica económica/fiscal; se scopean las lecturas/mutaciones.
-- -----------------------------------------------------------------------------
DO $patch_sale_v3$
DECLARE
  v_signature regprocedure := 'public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_signature) INTO v_def;

  v_old:=E'FROM public.ventas_requests_anulados AS vra\n    WHERE vra.request_id = p_request_id';
  v_new:=E'FROM public.ventas_requests_anulados AS vra\n    WHERE vra.organization_id = private.require_current_organization_id()\n      AND vra.request_id = p_request_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: cancelled request lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.ventas AS v\n  WHERE v.request_id = p_request_id\n  LIMIT 1;';
  v_new:=E'FROM public.ventas AS v\n  WHERE v.organization_id = private.require_current_organization_id()\n    AND v.request_id = p_request_id\n  LIMIT 1;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: sale idempotency lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.configuracion_negocio AS cn\n  ORDER BY cn.id\n  LIMIT 1;';
  v_new:=E'FROM public.configuracion_negocio AS cn\n  WHERE cn.organization_id = private.require_current_organization_id()\n  ORDER BY cn.id\n  LIMIT 1;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: business configuration singleton'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'WHERE e.auth_id = auth.uid()\n    AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_current_organization_id()\n    AND e.auth_id = auth.uid()\n    AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: sales actor lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.clientes AS c\n    WHERE c.id = p_cliente_id;';
  v_new:=E'FROM public.clientes AS c\n    WHERE c.organization_id = private.require_current_organization_id()\n      AND c.id = p_cliente_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: customer lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'LEFT JOIN public.proveedores AS pr\n      ON pr.id = p.proveedor_id\n    WHERE p.id = v_prod_id\n      AND COALESCE(p.activo, true) = true;';
  v_new:=E'LEFT JOIN public.proveedores AS pr\n      ON pr.organization_id = p.organization_id\n     AND pr.id = p.proveedor_id\n    WHERE p.organization_id = private.require_current_organization_id()\n      AND p.id = v_prod_id\n      AND COALESCE(p.activo, true) = true;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: product/provider lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.almacenes AS a\n    WHERE a.id = v_almacen_id;';
  v_new:=E'FROM public.almacenes AS a\n    WHERE a.organization_id = private.require_current_organization_id()\n      AND a.id = v_almacen_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: warehouse lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.inventario_almacen AS ia\n    WHERE ia.producto_id = v_prod_id\n      AND ia.almacen_id = v_almacen_id\n    FOR UPDATE;';
  v_new:=E'FROM public.inventario_almacen AS ia\n    WHERE ia.organization_id = private.require_current_organization_id()\n      AND ia.producto_id = v_prod_id\n      AND ia.almacen_id = v_almacen_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: inventory balance lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.inventario_almacen\n    SET cantidad =\n      COALESCE(cantidad, 0) - v_piezas_calculadas\n    WHERE producto_id = v_prod_id\n      AND almacen_id = v_almacen_id\n    RETURNING cantidad INTO v_saldo_actual;';
  v_new:=E'UPDATE public.inventario_almacen\n    SET cantidad =\n      COALESCE(cantidad, 0) - v_piezas_calculadas\n    WHERE organization_id = private.require_current_organization_id()\n      AND producto_id = v_prod_id\n      AND almacen_id = v_almacen_id\n    RETURNING cantidad INTO v_saldo_actual;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: inventory balance update'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.cotizaciones\n    SET estado = ''aprobada''\n    WHERE id = p_cotizacion_id;';
  v_new:=E'UPDATE public.cotizaciones\n    SET estado = ''aprobada''\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = p_cotizacion_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 patch mismatch: quotation approval'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  -- El autorizador proviene del actor real; aun así se scopea su lectura.
  v_old:=E'WHERE e.id = v_autorizado_por\n      AND COALESCE(e.activo, true) = true;';
  v_new:=E'WHERE e.organization_id = private.require_current_organization_id()\n      AND e.id = v_autorizado_por\n      AND COALESCE(e.activo, true) = true;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  EXECUTE v_def;
END;
$patch_sale_v3$;

-- El motor v3 es interno desde este punto.
REVOKE ALL ON FUNCTION public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)
  FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 4. Entry points de venta usados por Flutter: precheck tenant antes de precios/
--    trazabilidad. E-doc se bloquea hasta F3.7 para no usar series globales.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_sale_v4(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
  p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
  p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_tipo text:=lower(btrim(coalesce(p_tipo_comprobante,'ticket_interno')));
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0 AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales discount permission required';
  END IF;
  IF v_tipo='ticket' THEN v_tipo:='ticket_interno'; END IF;
  IF v_tipo<>'ticket_interno' THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Electronic invoicing is temporarily disabled until fiscal tenant rollout F3.7';
  END IF;
  PERFORM private.assert_sales_payload_in_current_organization(p_request_id,p_cliente_id,p_cotizacion_id,p_detalles);
  PERFORM public._assert_authorized_sale_prices_v1(p_detalles,p_fecha,p_cotizacion_id);
  PERFORM public._consume_sale_traceability_v1(p_request_id,p_detalles);
  RETURN public.process_sale_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,v_tipo,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.process_sale_with_units_v4(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
  p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
  p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_tipo text:=lower(btrim(coalesce(p_tipo_comprobante,'ticket_interno')));
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0 AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales discount permission required';
  END IF;
  IF v_tipo='ticket' THEN v_tipo:='ticket_interno'; END IF;
  IF v_tipo<>'ticket_interno' THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Electronic invoicing is temporarily disabled until fiscal tenant rollout F3.7';
  END IF;
  PERFORM private.assert_sales_payload_in_current_organization(p_request_id,p_cliente_id,p_cotizacion_id,p_detalles);
  PERFORM public._assert_authorized_sale_prices_v1(p_detalles,p_fecha,p_cotizacion_id);
  PERFORM public._consume_sale_traceability_v1(p_request_id,p_detalles);
  RETURN public.process_sale_with_units_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,v_tipo,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Cotizaciones: wrappers tenant-aware sobre el motor histórico.
-- -----------------------------------------------------------------------------
ALTER FUNCTION public.guardar_cotizacion_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb)
  RENAME TO _legacy_guardar_cotizacion_v2;
ALTER FUNCTION public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb)
  RENAME TO _legacy_guardar_cotizacion_with_units_v2;

REVOKE ALL ON FUNCTION public._legacy_guardar_cotizacion_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.guardar_cotizacion_v2(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_observaciones text,p_validez_dias integer,p_detalles jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  PERFORM private.assert_sales_payload_in_current_organization(p_request_id,p_cliente_id,NULL,p_detalles);
  RETURN public._legacy_guardar_cotizacion_v2(
    p_request_id,p_cliente_id,p_total,p_fecha,p_observaciones,p_validez_dias,p_detalles
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.guardar_cotizacion_with_units_v2(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_observaciones text,p_validez_dias integer,p_detalles jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  PERFORM private.assert_sales_payload_in_current_organization(p_request_id,p_cliente_id,NULL,p_detalles);
  RETURN public._legacy_guardar_cotizacion_with_units_v2(
    p_request_id,p_cliente_id,p_total,p_fecha,p_observaciones,p_validez_dias,p_detalles
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.actualizar_cotizaciones_vencidas()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id();
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant read permission required';
  END IF;
  UPDATE public.cotizaciones
  SET estado='vencida'
  WHERE organization_id=v_org
    AND estado='pendiente'
    AND (fecha+(coalesce(validez_dias,15)||' days')::interval)<now();
END;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_cotizacion_v2(p_cotizacion_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_estado text;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  SELECT lower(coalesce(estado,'pendiente')) INTO v_estado
  FROM public.cotizaciones
  WHERE organization_id=v_org AND id=p_cotizacion_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Quotation not found'; END IF;
  IF v_estado<>'pendiente' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Only pending quotations can be deleted';
  END IF;
  DELETE FROM public.cotizaciones WHERE organization_id=v_org AND id=p_cotizacion_id;
  RETURN jsonb_build_object('success',true,'cotizacion_id',p_cotizacion_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Pagos de venta y deuda de cliente.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_pago_venta_v1(p_pago_id bigint,p_venta_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_total numeric;
  v_total_pagado numeric;
  v_saldo numeric;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  PERFORM private.assert_sale_in_current_organization(p_venta_id);
  IF NOT EXISTS (SELECT 1 FROM public.pagos_venta WHERE organization_id=v_org AND id=p_pago_id) THEN
    RETURN jsonb_build_object('success',true,'idempotent',true);
  END IF;
  PERFORM private.assert_sale_payment_in_current_organization(p_pago_id,p_venta_id);

  -- Mientras F3.7 no tenantifique comprobantes, una venta con documento reservado
  -- se considera inmutable desde este RPC.
  IF EXISTS (SELECT 1 FROM public.comprobantes_electronicos WHERE venta_id=p_venta_id) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Payments of a sale with electronic document cannot be modified';
  END IF;

  SELECT total INTO v_total FROM public.ventas
  WHERE organization_id=v_org AND id=p_venta_id FOR UPDATE;

  DELETE FROM public.pagos_venta
  WHERE organization_id=v_org AND id=p_pago_id AND venta_id=p_venta_id;

  SELECT coalesce(sum(monto),0) INTO v_total_pagado
  FROM public.pagos_venta WHERE organization_id=v_org AND venta_id=p_venta_id;
  v_saldo:=greatest(round(coalesce(v_total,0)-v_total_pagado,2),0);

  UPDATE public.ventas
  SET saldo=v_saldo, estado=CASE WHEN v_saldo<=0.01 THEN 'pagado' ELSE 'pendiente' END
  WHERE organization_id=v_org AND id=p_venta_id;

  RETURN jsonb_build_object('success',true,'venta_id',p_venta_id,'pago_id',p_pago_id,'saldo',v_saldo);
END;
$$;

ALTER FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)
  RENAME TO _legacy_procesar_pago_deuda_v2;
REVOKE ALL ON FUNCTION public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2(
  p_request_id uuid,p_es_cliente boolean,p_deuda_id bigint,p_monto numeric,
  p_metodo text,p_fecha timestamptz,p_descontar_de_caja boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  PERFORM private.assert_sales_request_scope(p_request_id);

  IF p_es_cliente IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Supplier debt payments are disabled until purchases/expenses tenant rollout F3.6';
  END IF;
  IF lower(btrim(coalesce(p_metodo,'')))='efectivo' THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Cash debt payments are disabled until cash sessions are tenant-aware in F4.3';
  END IF;
  PERFORM private.assert_sale_in_current_organization(p_deuda_id);

  RETURN public._legacy_procesar_pago_deuda_v2(
    p_request_id,true,p_deuda_id,p_monto,p_metodo,p_fecha,false
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. Anulación: precheck tenant antes de tocar stock/fiscal legacy.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_venta_v2(p_venta_id bigint,p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id();
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ventas_requests_anulados
    WHERE organization_id=v_org AND venta_id_original=p_venta_id
  ) THEN
    RETURN jsonb_build_object('success',true,'idempotent',true);
  END IF;

  PERFORM private.assert_sale_in_current_organization(p_venta_id);
  PERFORM public._rebase_sale_stock_to_current_scale_v1(p_venta_id);
  RETURN public.anular_venta_v2_unscaled_legacy(p_venta_id,p_motivo);
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. Surface allowlist: sólo entrypoints realmente usados por Flutter.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.process_sale_authorized_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v1(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v2(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.anular_venta(bigint,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.anular_venta_with_units_v3(bigint,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.guardar_cotizacion_with_units_v1(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.procesar_pago_deuda(boolean,bigint,numeric,text,timestamp,boolean) FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.guardar_cotizacion_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.actualizar_cotizaciones_vencidas() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.eliminar_cotizacion_v2(bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.eliminar_pago_venta_v1(bigint,bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.anular_venta_v2(bigint,text) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_cotizacion_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_cotizaciones_vencidas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_cotizacion_v2(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_pago_venta_v1(bigint,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_venta_v2(bigint,text) TO authenticated;

COMMIT;
