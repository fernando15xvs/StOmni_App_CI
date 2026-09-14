-- Fase 3.7 SaaS (RPC): entrypoints fiscales usados por Flutter y motores
-- comerciales/fiscales internos scopeados por organización.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Assertions privadas reutilizables.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.assert_fiscal_comprobante_in_current_organization(p_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos
    WHERE organization_id=v_org AND id=p_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Electronic document not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_fiscal_nota_in_current_organization(p_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.notas_credito
    WHERE organization_id=v_org AND id=p_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Credit note not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_fiscal_guia_in_current_organization(p_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.guias_remision
    WHERE organization_id=v_org AND id=p_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Dispatch guide not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_credit_note_payload_in_current_organization(
  p_comprobante_id uuid,
  p_detalles jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_item jsonb;
  v_detalle_id bigint;
BEGIN
  PERFORM private.assert_fiscal_comprobante_in_current_organization(p_comprobante_id);

  IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Credit note details must be an array';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_detalles)
  LOOP
    v_detalle_id:=NULLIF(v_item->>'detalle_venta_id','')::bigint;
    IF v_detalle_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.detalle_ventas
      WHERE organization_id=v_org AND id=v_detalle_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Sale detail not available in current organization';
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_gre_payload_in_current_organization(
  p_guia_id uuid,
  p_venta_id bigint,
  p_transferencia_id bigint,
  p_guia_remitente_id uuid,
  p_transportista_id bigint,
  p_conductor_id bigint,
  p_vehiculo_id bigint,
  p_transportista_transbordo_id bigint,
  p_agencia_origen_id bigint,
  p_agencia_destino_id bigint,
  p_detalles jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_item jsonb;
  v_id bigint;
BEGIN
  IF p_guia_id IS NOT NULL THEN
    PERFORM private.assert_fiscal_guia_in_current_organization(p_guia_id);
  END IF;
  IF p_venta_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.ventas WHERE organization_id=v_org AND id=p_venta_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Sale not available in current organization';
  END IF;
  IF p_transferencia_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.transferencias_stock WHERE organization_id=v_org AND id=p_transferencia_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Stock transfer not available in current organization';
  END IF;
  IF p_guia_remitente_id IS NOT NULL THEN
    PERFORM private.assert_fiscal_guia_in_current_organization(p_guia_remitente_id);
  END IF;
  IF p_transportista_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_transportistas WHERE organization_id=v_org AND id=p_transportista_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Carrier not available in current organization';
  END IF;
  IF p_conductor_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_conductores WHERE organization_id=v_org AND id=p_conductor_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Driver not available in current organization';
  END IF;
  IF p_vehiculo_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_vehiculos WHERE organization_id=v_org AND id=p_vehiculo_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Vehicle not available in current organization';
  END IF;
  IF p_transportista_transbordo_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_transportistas WHERE organization_id=v_org AND id=p_transportista_transbordo_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Transshipment carrier not available in current organization';
  END IF;
  IF p_agencia_origen_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_transportistas_agencias WHERE organization_id=v_org AND id=p_agencia_origen_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Origin agency not available in current organization';
  END IF;
  IF p_agencia_destino_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gre_transportistas_agencias WHERE organization_id=v_org AND id=p_agencia_destino_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Destination agency not available in current organization';
  END IF;

  IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Dispatch guide details must be an array';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_detalles)
  LOOP
    v_id:=NULLIF(v_item->>'producto_id','')::bigint;
    IF v_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.productos WHERE organization_id=v_org AND id=v_id
    ) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Product not available in current organization'; END IF;

    v_id:=NULLIF(v_item->>'detalle_venta_id','')::bigint;
    IF v_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.detalle_ventas WHERE organization_id=v_org AND id=v_id
    ) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Sale detail not available in current organization'; END IF;

    v_id:=NULLIF(v_item->>'transferencia_id','')::bigint;
    IF v_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.transferencias_stock WHERE organization_id=v_org AND id=v_id
    ) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Stock transfer detail not available in current organization'; END IF;

    v_id:=NULLIF(v_item->>'almacen_id','')::bigint;
    IF v_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.almacenes WHERE organization_id=v_org AND id=v_id
    ) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Warehouse not available in current organization'; END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_fiscal_comprobante_in_current_organization(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_fiscal_nota_in_current_organization(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_fiscal_guia_in_current_organization(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_credit_note_payload_in_current_organization(uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_gre_payload_in_current_organization(uuid,bigint,bigint,uuid,bigint,bigint,bigint,bigint,bigint,bigint,jsonb) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 2. NC: precheck en v3 y scope interno de v1/legacy.
-- -----------------------------------------------------------------------------
DO $patch_nc_v3$
DECLARE
  v_sig regprocedure := 'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'BEGIN\n  IF p_detalles IS NULL OR jsonb_typeof(p_detalles) IS DISTINCT FROM ''array'' THEN';
  v_new:=E'BEGIN\n  PERFORM private.assert_credit_note_payload_in_current_organization(p_comprobante_id,p_detalles);\n  IF p_detalles IS NULL OR jsonb_typeof(p_detalles) IS DISTINCT FROM ''array'' THEN';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC v3 patch mismatch: entry precheck'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.comprobantes_electronicos ce\n  WHERE ce.id = p_comprobante_id\n  FOR SHARE;';
  v_new:=E'FROM public.comprobantes_electronicos ce\n  WHERE ce.organization_id = private.require_current_organization_id()\n    AND ce.id = p_comprobante_id\n  FOR SHARE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC v3 patch mismatch: comprobante'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_nc_v3$;

DO $patch_nc_v1$
DECLARE
  v_sig regprocedure := 'public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'FROM public.comprobantes_electronicos\n    WHERE id = p_comprobante_id\n    FOR SHARE;';
  v_new:=E'FROM public.comprobantes_electronicos\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = p_comprobante_id\n    FOR SHARE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC v1 patch mismatch: comprobante'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_nc_v1$;

DO $patch_nc_legacy$
DECLARE
  v_sig regprocedure := 'public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'FROM public.notas_credito\n  WHERE request_id = p_request_id;';
  v_new:=E'FROM public.notas_credito\n  WHERE organization_id = private.require_current_organization_id()\n    AND request_id = p_request_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC legacy patch mismatch: request replay'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.comprobantes_electronicos AS ce\n  JOIN public.ventas AS v ON v.id = ce.venta_id\n  WHERE ce.id = p_comprobante_id';
  v_new:=E'FROM public.comprobantes_electronicos AS ce\n  JOIN public.ventas AS v ON v.organization_id = ce.organization_id AND v.id = ce.venta_id\n  WHERE ce.organization_id = private.require_current_organization_id()\n    AND ce.id = p_comprobante_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC legacy patch mismatch: source document'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.notas_credito AS nc\n  WHERE nc.comprobante_id = p_comprobante_id';
  v_new:=E'FROM public.notas_credito AS nc\n  WHERE nc.organization_id = private.require_current_organization_id()\n    AND nc.comprobante_id = p_comprobante_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC legacy patch mismatch: committed notes'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.series_comprobantes\n  SET\n    ultimo_correlativo = ultimo_correlativo + 1,\n    updated_at = now()\n  WHERE tipo_documento_sunat = v_tipo_serie\n    AND serie = v_serie\n    AND activo = true';
  v_new:=E'UPDATE public.series_comprobantes\n  SET\n    ultimo_correlativo = ultimo_correlativo + 1,\n    updated_at = now()\n  WHERE organization_id = private.require_current_organization_id()\n    AND tipo_documento_sunat = v_tipo_serie\n    AND serie = v_serie\n    AND activo = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC legacy patch mismatch: series'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_nc_legacy$;

DO $patch_nc_availability_v2$
DECLARE
  v_sig regprocedure := 'public.obtener_disponibilidad_nota_credito_v2(uuid)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'BEGIN\n  v_base := public.obtener_disponibilidad_nota_credito(p_comprobante_id);';
  v_new:=E'BEGIN\n  PERFORM private.assert_fiscal_comprobante_in_current_organization(p_comprobante_id);\n  v_base := public.obtener_disponibilidad_nota_credito(p_comprobante_id);';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 NC availability patch mismatch'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_nc_availability_v2$;

-- -----------------------------------------------------------------------------
-- 3. GRE: precheck v4; v3 scopea replay, edición, configuración y series.
-- -----------------------------------------------------------------------------
DO $patch_gre_v4$
DECLARE
  v_sig regprocedure := 'public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'BEGIN\n  IF p_cantidad_bultos IS NOT NULL AND p_cantidad_bultos <= 0 THEN';
  v_new:=E'BEGIN\n  PERFORM private.assert_gre_payload_in_current_organization(\n    p_guia_id,p_venta_id,p_transferencia_id,p_guia_remitente_id,\n    p_transportista_id,p_conductor_id,p_vehiculo_id,p_transportista_transbordo_id,\n    p_agencia_origen_id,p_agencia_destino_id,p_detalles\n  );\n  IF p_cantidad_bultos IS NOT NULL AND p_cantidad_bultos <= 0 THEN';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE v4 patch mismatch: precheck'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_gre_v4$;

DO $patch_gre_v3$
DECLARE
  v_sig regprocedure := 'public.guardar_guia_remision_v3(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'FROM public.guias_remision\n    WHERE id = p_guia_id\n    FOR UPDATE;';
  v_new:=E'FROM public.guias_remision\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = p_guia_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE v3 patch mismatch: edit'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.guias_remision\n    WHERE request_id = p_request_id\n    FOR UPDATE;';
  v_new:=E'FROM public.guias_remision\n    WHERE organization_id = private.require_current_organization_id()\n      AND request_id = p_request_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE v3 patch mismatch: replay'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.configuracion_negocio\n      ORDER BY id\n      LIMIT 1;';
  v_new:=E'FROM public.configuracion_negocio\n      WHERE organization_id = private.require_current_organization_id()\n      ORDER BY id\n      LIMIT 1;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'SELECT ruc FROM public.configuracion_negocio ORDER BY id LIMIT 1';
  v_new:=E'SELECT ruc FROM public.configuracion_negocio WHERE organization_id = private.require_current_organization_id() ORDER BY id LIMIT 1';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'FROM public.configuracion_negocio ORDER BY id LIMIT 1';
  v_new:=E'FROM public.configuracion_negocio WHERE organization_id = private.require_current_organization_id() ORDER BY id LIMIT 1';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'FROM public.series_comprobantes\n      WHERE tipo_documento_sunat = v_tipo_serie\n        AND activo = true\n      FOR UPDATE;';
  v_new:=E'FROM public.series_comprobantes\n      WHERE organization_id = private.require_current_organization_id()\n        AND tipo_documento_sunat = v_tipo_serie\n        AND activo = true\n      FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE v3 patch mismatch: series select'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.series_comprobantes\n      SET ultimo_correlativo = v_correlativo,\n          updated_at = now()\n      WHERE tipo_documento_sunat = v_tipo_serie\n        AND serie = v_serie;';
  v_new:=E'UPDATE public.series_comprobantes\n      SET ultimo_correlativo = v_correlativo,\n          updated_at = now()\n      WHERE organization_id = private.require_current_organization_id()\n        AND tipo_documento_sunat = v_tipo_serie\n        AND serie = v_serie;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE v3 patch mismatch: series update'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_gre_v3$;

CREATE OR REPLACE FUNCTION public.eliminar_borrador_guia_v1(p_guia_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_guia public.guias_remision%ROWTYPE;
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;

  SELECT * INTO v_guia
  FROM public.guias_remision
  WHERE organization_id=v_org AND id=p_guia_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;
  IF v_guia.estado<>'borrador' THEN RAISE EXCEPTION 'Solo se pueden eliminar guías en estado borrador'; END IF;
  IF v_guia.ticket_sunat IS NOT NULL OR v_guia.enviado_at IS NOT NULL THEN
    RAISE EXCEPTION 'La guía tiene información de envío y no puede eliminarse';
  END IF;

  DELETE FROM public.guias_remision_detalles WHERE organization_id=v_org AND guia_id=p_guia_id;
  DELETE FROM public.guias_remision WHERE organization_id=v_org AND id=p_guia_id;
  RETURN jsonb_build_object('success',true,'guia_id',p_guia_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Baja tributaria: idempotencia y origen siempre dentro del tenant.
-- -----------------------------------------------------------------------------
DO $patch_baja$
DECLARE
  v_sig regprocedure := 'public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'FROM public.solicitudes_baja_tributaria\n  WHERE request_id = p_request_id;';
  v_new:=E'FROM public.solicitudes_baja_tributaria\n  WHERE organization_id = private.require_current_organization_id()\n    AND request_id = p_request_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 baja patch mismatch: replay'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.comprobantes_electronicos ce\n    WHERE ce.id = p_origen_id\n    FOR UPDATE;';
  v_new:=E'FROM public.comprobantes_electronicos ce\n    WHERE ce.organization_id = private.require_current_organization_id()\n      AND ce.id = p_origen_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 baja patch mismatch: comprobante'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.notas_credito nc\n      WHERE nc.comprobante_id = p_origen_id';
  v_new:=E'FROM public.notas_credito nc\n      WHERE nc.organization_id = private.require_current_organization_id()\n        AND nc.comprobante_id = p_origen_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 baja patch mismatch: active notes'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'WHERE id = p_origen_id;';
  v_new:=E'WHERE organization_id = private.require_current_organization_id()\n      AND id = p_origen_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 baja patch mismatch: source update'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.notas_credito nc\n    WHERE nc.id = p_origen_id\n    FOR UPDATE;';
  v_new:=E'FROM public.notas_credito nc\n    WHERE nc.organization_id = private.require_current_organization_id()\n      AND nc.id = p_origen_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 baja patch mismatch: nota'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  EXECUTE v_def;
END;
$patch_baja$;

-- -----------------------------------------------------------------------------
-- 5. Listado fiscal: reconstrucción explícita tenant-aware.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listar_documentos_electronicos_v1(
  p_fecha_inicio timestamptz,
  p_fecha_fin_exclusiva timestamptz,
  p_limite integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  categoria text,tipo_label text,id text,venta_id bigint,numero text,estado text,
  total numeric,tercero text,fecha_documento timestamptz,descripcion_sunat text,
  pdf_path text,xml_path text,cdr_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite,50),10),100);
  v_offset integer := GREATEST(COALESCE(p_offset,0),0);
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant read permission required';
  END IF;
  IF p_fecha_inicio IS NULL OR p_fecha_fin_exclusiva IS NULL OR p_fecha_fin_exclusiva<=p_fecha_inicio THEN
    RAISE EXCEPTION 'Rango de fechas inválido';
  END IF;

  RETURN QUERY
  WITH documentos AS (
    SELECT CASE WHEN lower(coalesce(ce.tipo_documento_sunat,'')) IN ('factura','01') THEN 'factura' ELSE 'boleta' END::text categoria,
      CASE WHEN lower(coalesce(ce.tipo_documento_sunat,'')) IN ('factura','01') THEN 'Factura' ELSE 'Boleta' END::text tipo_label,
      ce.id::text id,ce.venta_id,(ce.serie||'-'||ce.correlativo)::text numero,ce.estado::text,ce.total::numeric total,
      coalesce(nullif(ce.cliente_razon_social,''),'Cliente general')::text tercero,
      coalesce(ce.fecha_emision_ts,ce.fecha_emision::timestamp AT TIME ZONE 'America/Lima',ce.created_at) fecha_documento,
      ce.descripcion_sunat::text,ce.pdf_path::text,ce.xml_path::text,ce.cdr_path::text
    FROM public.comprobantes_electronicos ce WHERE ce.organization_id=v_org
    UNION ALL
    SELECT 'nota'::text,'Nota de crédito'::text,nc.id::text,nc.venta_id,(nc.serie||'-'||nc.correlativo)::text,nc.estado::text,nc.total::numeric,
      coalesce(nullif(nc.motivo_descripcion,''),'Nota de crédito')::text,
      coalesce(nc.fecha_emision_ts,nc.fecha_emision::timestamp AT TIME ZONE 'America/Lima',nc.created_at),
      nc.descripcion_sunat::text,nc.pdf_path::text,nc.xml_path::text,nc.cdr_path::text
    FROM public.notas_credito nc WHERE nc.organization_id=v_org
    UNION ALL
    SELECT 'guia'::text,CASE WHEN g.tipo_guia='transportista' THEN 'GRE Transportista' ELSE 'GRE Remitente' END::text,
      g.id::text,g.venta_id,(g.serie||'-'||g.correlativo)::text,g.estado::text,NULL::numeric,
      coalesce(nullif(g.destinatario_razon_social,''),'Destinatario')::text,
      coalesce(g.fecha_emision,g.created_at),g.descripcion_sunat::text,g.pdf_path::text,g.xml_path::text,g.cdr_path::text
    FROM public.guias_remision g WHERE g.organization_id=v_org
  )
  SELECT d.categoria,d.tipo_label,d.id,d.venta_id,d.numero,d.estado,d.total,d.tercero,d.fecha_documento,
    d.descripcion_sunat,d.pdf_path,d.xml_path,d.cdr_path
  FROM documentos d
  WHERE d.fecha_documento>=p_fecha_inicio AND d.fecha_documento<p_fecha_fin_exclusiva
  ORDER BY d.fecha_documento DESC,d.id DESC
  LIMIT v_limite OFFSET v_offset;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Reabrir boleta/factura y scopear la rama fiscal de process_sale_v3.
-- -----------------------------------------------------------------------------
DO $patch_sale_fiscal$
DECLARE
  v_sig regprocedure := 'public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'FROM public.comprobantes_electronicos AS ce\n    WHERE ce.venta_id = v_existing_venta_id\n    ORDER BY ce.created_at DESC';
  v_new:=E'FROM public.comprobantes_electronicos AS ce\n    WHERE ce.organization_id = private.require_current_organization_id()\n      AND ce.venta_id = v_existing_venta_id\n    ORDER BY ce.created_at DESC';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 sale fiscal patch mismatch: replay document'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.series_comprobantes AS sc\n    WHERE sc.tipo_documento_sunat = v_tipo_comprobante\n      AND sc.activo = true\n    FOR UPDATE;';
  v_new:=E'FROM public.series_comprobantes AS sc\n    WHERE sc.organization_id = private.require_current_organization_id()\n      AND sc.tipo_documento_sunat = v_tipo_comprobante\n      AND sc.activo = true\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 sale fiscal patch mismatch: series select'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.series_comprobantes\n    SET ultimo_correlativo = ultimo_correlativo + 1\n    WHERE id = v_serie_id';
  v_new:=E'UPDATE public.series_comprobantes\n    SET ultimo_correlativo = ultimo_correlativo + 1\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = v_serie_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 sale fiscal patch mismatch: series update'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_sale_fiscal$;

DO $reopen_sales_entrypoints$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_old text:=E'IF v_tipo=''ticket'' THEN v_tipo:=''ticket_interno''; END IF;\n  IF v_tipo<>''ticket_interno'' THEN\n    RAISE EXCEPTION USING ERRCODE=''0A000'', MESSAGE=''Electronic invoicing is temporarily disabled until fiscal tenant rollout F3.7'';\n  END IF;';
  v_new text:=E'IF v_tipo=''ticket'' THEN v_tipo:=''ticket_interno''; END IF;\n  IF v_tipo NOT IN (''ticket_interno'',''boleta'',''factura'') THEN\n    RAISE EXCEPTION USING ERRCODE=''22023'', MESSAGE=''Unsupported sale document type'';\n  END IF;';
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure,
    'public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure
  ] LOOP
    SELECT pg_get_functiondef(v_sig) INTO v_def;
    IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 sales entrypoint patch mismatch: %',v_sig; END IF;
    EXECUTE replace(v_def,v_old,v_new);
  END LOOP;
END;
$reopen_sales_entrypoints$;

-- -----------------------------------------------------------------------------
-- 7. Allowlist: sólo entrypoints actuales quedan ejecutables por authenticated.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.crear_nota_credito_with_units_v2(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.obtener_disponibilidad_nota_credito(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.crear_guia_remision_v1(uuid,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.guardar_guia_remision_v2(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.guardar_guia_remision_v3(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb,boolean,bigint,bigint,bigint,text) FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz) TO authenticated;
REVOKE ALL ON FUNCTION public.obtener_disponibilidad_nota_credito_v2(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.obtener_disponibilidad_nota_credito_v2(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text) TO authenticated;
REVOKE ALL ON FUNCTION public.eliminar_borrador_guia_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.eliminar_borrador_guia_v1(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.solicitar_baja_tributaria_v1(uuid,text,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.solicitar_baja_tributaria_v1(uuid,text,uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer) TO authenticated;

COMMIT;
