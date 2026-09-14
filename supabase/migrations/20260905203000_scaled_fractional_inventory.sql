BEGIN;

-- Fractional inventory without replacing the historical integer stock schema.
-- A product profile defines a base precision. Stock is persisted in minor units:
-- kg precision=3 => 1 stored unit = 0.001 kg.
ALTER TABLE public.detalle_ventas
  ADD COLUMN IF NOT EXISTS stock_scale_snapshot integer NOT NULL DEFAULT 1
  CHECK (stock_scale_snapshot BETWEEN 1 AND 1000000);
ALTER TABLE public.detalle_cotizaciones
  ADD COLUMN IF NOT EXISTS stock_scale_snapshot integer NOT NULL DEFAULT 1
  CHECK (stock_scale_snapshot BETWEEN 1 AND 1000000);
ALTER TABLE public.inventario_movimientos
  ADD COLUMN IF NOT EXISTS stock_scale_snapshot integer NOT NULL DEFAULT 1
  CHECK (stock_scale_snapshot BETWEEN 1 AND 1000000);

CREATE OR REPLACE FUNCTION public._product_unit_storage_scale(p_profile jsonb)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_version integer;
  v_base jsonb;
  v_precision integer;
BEGIN
  IF jsonb_typeof(p_profile) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;
  v_version := NULLIF(p_profile->>'schema_version', '')::integer;
  IF v_version = 1 THEN RETURN 1; END IF;
  IF v_version <> 2 THEN RAISE EXCEPTION 'Versión de perfil no compatible'; END IF;
  SELECT value INTO v_base
    FROM jsonb_array_elements(p_profile->'presentations')
    WHERE value->>'code' = p_profile->>'base_code';
  IF v_base IS NULL THEN RAISE EXCEPTION 'La unidad base no existe'; END IF;
  v_precision := NULLIF(v_base->>'precision', '')::integer;
  IF v_precision NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION 'Precisión base fuera de rango';
  END IF;
  RETURN power(10::numeric, v_precision)::integer;
END;
$function$;

CREATE OR REPLACE FUNCTION public._validate_product_unit_profile_v2(p_profile jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_version integer;
  v_row jsonb;
  v_codes text[] := ARRAY[]::text[];
  v_code text;
  v_factor numeric;
  v_precision integer;
  v_scale integer;
  v_min_stored numeric;
  v_base_count integer := 0;
BEGIN
  IF jsonb_typeof(p_profile) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_profile->'schema_version') IS DISTINCT FROM 'number'
     OR jsonb_typeof(p_profile->'base_code') IS DISTINCT FROM 'string'
     OR jsonb_typeof(p_profile->'presentations') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_profile->'presentations') NOT BETWEEN 1 AND 20
     OR (p_profile->>'base_code') !~ '^[a-z][a-z0-9_]{0,39}$' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;
  v_version := (p_profile->>'schema_version')::integer;
  IF v_version = 1 THEN
    PERFORM public._validate_product_unit_profile(p_profile);
    RETURN;
  END IF;
  IF v_version <> 2 THEN RAISE EXCEPTION 'Versión de perfil no compatible'; END IF;
  v_scale := public._product_unit_storage_scale(p_profile);

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_profile->'presentations') LOOP
    IF jsonb_typeof(v_row) <> 'object'
       OR jsonb_typeof(v_row->'code') <> 'string'
       OR jsonb_typeof(v_row->'singular') <> 'string'
       OR jsonb_typeof(v_row->'plural') <> 'string'
       OR jsonb_typeof(v_row->'factor') <> 'number'
       OR jsonb_typeof(v_row->'fractional') <> 'boolean'
       OR jsonb_typeof(v_row->'precision') <> 'number' THEN
      RAISE EXCEPTION 'Presentación incompleta';
    END IF;
    v_code := v_row->>'code';
    v_factor := (v_row->>'factor')::numeric;
    v_precision := (v_row->>'precision')::integer;
    IF v_code !~ '^[a-z][a-z0-9_]{0,39}$'
       OR v_code = ANY(v_codes)
       OR length(trim(v_row->>'singular')) NOT BETWEEN 1 AND 60
       OR length(trim(v_row->>'plural')) NOT BETWEEN 1 AND 60
       OR v_row->>'singular' <> trim(v_row->>'singular')
       OR v_row->>'plural' <> trim(v_row->>'plural')
       OR (v_row->>'singular') ~ '[[:cntrl:]]'
       OR (v_row->>'plural') ~ '[[:cntrl:]]'
       OR v_factor::text IN ('NaN','Infinity','-Infinity')
       OR v_factor <= 0 OR v_factor > 1000000000000
       OR v_precision NOT BETWEEN 0 AND 6
       OR ((v_row->>'fractional')::boolean <> (v_precision > 0)) THEN
      RAISE EXCEPTION 'Presentación fuera del contrato decimal';
    END IF;
    -- The smallest valid commercial step must map exactly to integer minor stock.
    v_min_stored := v_factor * v_scale / power(10::numeric, v_precision);
    IF v_min_stored <> trunc(v_min_stored) OR v_min_stored < 1 THEN
      RAISE EXCEPTION 'La presentación % requiere más precisión de inventario', v_code;
    END IF;
    v_codes := array_append(v_codes, v_code);
    IF v_code = p_profile->>'base_code' THEN
      v_base_count := v_base_count + 1;
      IF v_factor <> 1 THEN RAISE EXCEPTION 'La unidad base debe tener factor 1'; END IF;
    END IF;
  END LOOP;
  IF v_base_count <> 1 THEN
    RAISE EXCEPTION 'La unidad base debe aparecer exactamente una vez';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._enforce_product_unit_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  PERFORM public._validate_product_unit_profile_v2(NEW.profile);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v2(
  p_product_id bigint,
  p_expected_revision bigint,
  p_profile jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_current public.product_unit_profiles%ROWTYPE;
  v_saved public.product_unit_profiles%ROWTYPE;
  v_old_scale integer := 1;
  v_new_scale integer;
  v_num numeric;
  v_ratio numeric;
BEGIN
  IF NOT public.app_es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede editar presentaciones'; END IF;
  IF p_product_id IS NULL OR p_product_id <= 0 OR p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'Producto o revisión inválidos';
  END IF;
  PERFORM public._validate_product_unit_profile_v2(p_profile);
  v_new_scale := public._product_unit_storage_scale(p_profile);
  PERFORM 1 FROM public.productos p WHERE p.id = p_product_id AND COALESCE(p.activo,true) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;
  SELECT * INTO v_current FROM public.product_unit_profiles WHERE product_id = p_product_id FOR UPDATE;
  IF FOUND THEN
    IF v_current.revision <> p_expected_revision THEN
      RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='La configuración cambió en otro equipo';
    END IF;
    IF v_current.profile->>'base_code' <> p_profile->>'base_code' THEN
      RAISE EXCEPTION 'La unidad base no puede sustituirse sin una conversión explícita';
    END IF;
    v_old_scale := public._product_unit_storage_scale(v_current.profile);
  ELSE
    IF p_expected_revision <> 0 THEN
      RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='La configuración ya no existe';
    END IF;
  END IF;

  IF v_new_scale <> v_old_scale THEN
    v_ratio := v_new_scale::numeric / v_old_scale::numeric;
    PERFORM 1 FROM public.inventario_almacen WHERE producto_id = p_product_id FOR UPDATE;
    IF v_new_scale > v_old_scale THEN
      IF EXISTS (
        SELECT 1 FROM public.inventario_almacen
        WHERE producto_id=p_product_id AND abs(cantidad::numeric * v_ratio) > 2147483647
      ) THEN RAISE EXCEPTION 'El stock excedería el rango al cambiar la precisión'; END IF;
      UPDATE public.inventario_almacen
        SET cantidad = (cantidad::numeric * v_ratio)::integer
        WHERE producto_id = p_product_id;
      -- Existing reversible transactions must use the new current storage scale.
      UPDATE public.detalle_ventas
        SET piezas_reales = (piezas_reales::numeric * v_ratio)::integer,
            precio_unitario = CASE WHEN precio_unitario IS NULL THEN NULL ELSE precio_unitario / v_ratio END,
            stock_scale_snapshot = v_new_scale
        WHERE producto_id = p_product_id AND COALESCE(piezas_reales,0) <> 0;
      UPDATE public.detalle_cotizaciones
        SET piezas_reales = (piezas_reales::numeric * v_ratio)::integer,
            precio_unitario = CASE WHEN precio_unitario IS NULL THEN NULL ELSE precio_unitario / v_ratio END,
            stock_scale_snapshot = v_new_scale
        WHERE producto_id = p_product_id AND COALESCE(piezas_reales,0) <> 0;
      IF to_regclass('public.notas_credito_detalles') IS NOT NULL THEN
        UPDATE public.notas_credito_detalles
          SET piezas_reales = (piezas_reales::numeric * v_ratio)::integer
          WHERE producto_id = p_product_id AND COALESCE(piezas_reales,0) <> 0;
      END IF;
    ELSE
      -- Reducing scale is only safe when every operational quantity is divisible.
      IF EXISTS (SELECT 1 FROM public.inventario_almacen WHERE producto_id=p_product_id AND cantidad % (v_old_scale/v_new_scale) <> 0)
         OR EXISTS (SELECT 1 FROM public.detalle_ventas WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % (v_old_scale/v_new_scale) <> 0)
         OR EXISTS (SELECT 1 FROM public.detalle_cotizaciones WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % (v_old_scale/v_new_scale) <> 0) THEN
        RAISE EXCEPTION 'No se puede reducir la precisión sin perder cantidades existentes';
      END IF;
      UPDATE public.inventario_almacen SET cantidad = cantidad / (v_old_scale/v_new_scale) WHERE producto_id=p_product_id;
      UPDATE public.detalle_ventas
        SET piezas_reales = piezas_reales / (v_old_scale/v_new_scale),
            precio_unitario = CASE WHEN precio_unitario IS NULL THEN NULL ELSE precio_unitario * (v_old_scale/v_new_scale) END,
            stock_scale_snapshot = v_new_scale
        WHERE producto_id=p_product_id;
      UPDATE public.detalle_cotizaciones
        SET piezas_reales = piezas_reales / (v_old_scale/v_new_scale),
            precio_unitario = CASE WHEN precio_unitario IS NULL THEN NULL ELSE precio_unitario * (v_old_scale/v_new_scale) END,
            stock_scale_snapshot = v_new_scale
        WHERE producto_id=p_product_id;
      IF to_regclass('public.notas_credito_detalles') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM public.notas_credito_detalles WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % (v_old_scale/v_new_scale) <> 0) THEN
          RAISE EXCEPTION 'Notas de crédito existentes impiden reducir la precisión';
        END IF;
        UPDATE public.notas_credito_detalles
          SET piezas_reales = piezas_reales / (v_old_scale/v_new_scale)
          WHERE producto_id=p_product_id;
      END IF;
    END IF;
  END IF;

  IF FOUND THEN
    UPDATE public.product_unit_profiles
      SET profile=p_profile, revision=revision+1, updated_at=now()
      WHERE product_id=p_product_id RETURNING * INTO v_saved;
  ELSE
    INSERT INTO public.product_unit_profiles(product_id,revision,profile)
      VALUES(p_product_id,1,p_profile) RETURNING * INTO v_saved;
  END IF;
  RETURN jsonb_build_object('revision',v_saved.revision,'profile',v_saved.profile,'storage_scale',v_new_scale);
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_sale_with_units_v2(
  p_request_id uuid, p_cliente_id bigint, p_total numeric,
  p_fecha timestamptz, p_es_credito boolean, p_monto_abono numeric,
  p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint,
  p_vendedor_id bigint, p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric, p_descuento_global_monto numeric,
  p_motivo_descuento text, p_subtotal_bruto numeric,
  p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_detail jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_snapshots jsonb := '[]'::jsonb;
  v_profile public.product_unit_profiles%ROWTYPE;
  v_presentation jsonb;
  v_product_type text;
  v_quantity numeric;
  v_base numeric;
  v_factor numeric;
  v_scale integer;
  v_stored numeric;
  v_price numeric;
  v_subtotal numeric;
  v_legacy_unit text;
  v_base_label text;
  v_result jsonb;
  v_sale_id bigint;
BEGIN
  IF NOT public.app_empleado_activo() THEN RAISE EXCEPTION 'Acceso denegado'; END IF;
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' OR jsonb_array_length(p_detalles)=0 THEN
    RAISE EXCEPTION 'La venta requiere detalles';
  END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request_id es obligatorio para evitar ventas duplicadas'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  IF EXISTS (SELECT 1 FROM public.ventas WHERE request_id=p_request_id) THEN
    RETURN public.process_sale_v3(p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    IF NOT (v_detail ? 'unit_profile_revision') THEN
      v_normalized := v_normalized || jsonb_build_array(v_detail);
      v_snapshots := v_snapshots || jsonb_build_array(NULL);
      CONTINUE;
    END IF;
    SELECT lower(COALESCE(p.tipo_venta,'')) INTO v_product_type
      FROM public.productos p WHERE p.id=(v_detail->>'producto_id')::bigint AND COALESCE(p.activo,true) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;
    SELECT u.* INTO v_profile FROM public.product_unit_profiles u
      WHERE u.product_id=(v_detail->>'producto_id')::bigint FOR SHARE;
    IF NOT FOUND OR v_profile.revision<>(v_detail->>'unit_profile_revision')::bigint THEN
      RAISE EXCEPTION 'Las presentaciones del producto cambiaron; vuelve a seleccionarlo';
    END IF;
    PERFORM public._validate_product_unit_profile_v2(v_profile.profile);
    v_scale := public._product_unit_storage_scale(v_profile.profile);
    SELECT value INTO v_presentation FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code'=v_detail->>'tipo_unidad';
    IF v_presentation IS NULL THEN RAISE EXCEPTION 'La presentación ya no existe'; END IF;
    SELECT value->>'singular' INTO v_base_label FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code'=v_profile.profile->>'base_code';
    v_quantity := NULLIF(v_detail->>'cantidad','')::numeric;
    v_factor := (v_presentation->>'factor')::numeric;
    v_base := v_quantity * v_factor;
    v_stored := v_base * v_scale;
    v_subtotal := NULLIF(v_detail->>'subtotal','')::numeric;
    v_price := NULLIF(v_detail->>'precio_unitario_comercial','')::numeric;
    IF v_quantity IS NULL OR v_quantity<=0 OR v_stored<>trunc(v_stored)
       OR v_stored<=0 OR v_stored>2147483647 OR v_subtotal IS NULL OR v_subtotal<0
       OR v_price IS NULL OR v_price<0 OR abs(v_subtotal-v_quantity*v_price)>0.02
       OR NULLIF(v_detail->>'piezas_reales','')::numeric IS DISTINCT FROM v_stored
       OR COALESCE(NULLIF(v_detail->>'stock_scale','')::integer,v_scale)<>v_scale THEN
      RAISE EXCEPTION 'Cantidad, escala o precio comercial inconsistente';
    END IF;
    v_legacy_unit := CASE WHEN v_product_type IN ('paquetes','paquete','caja_paquetes') THEN 'paquete'
                          WHEN v_product_type IN ('solo_cajas','caja') THEN 'caja' ELSE 'unidad' END;
    v_normalized := v_normalized || jsonb_build_array(v_detail || jsonb_build_object(
      'cantidad',v_stored::integer,
      'piezas_reales',v_stored::integer,
      'tipo_unidad',v_legacy_unit,
      'precio_unitario',round(v_subtotal/v_stored,4),
      'precio_unitario_comercial',round(v_subtotal/v_stored,4)
    ));
    v_snapshots := v_snapshots || jsonb_build_array(jsonb_build_object(
      'schema_version',2,'code',v_presentation->>'code','singular',v_presentation->>'singular',
      'plural',v_presentation->>'plural','factor',v_factor,'quantity',v_quantity,
      'commercial_price',v_price,'base_quantity',v_base,'base_code',v_profile.profile->>'base_code',
      'base_label',v_base_label,'revision',v_profile.revision,'storage_scale',v_scale,
      'profile',v_profile.profile
    ));
  END LOOP;

  v_result := public.process_sale_v3(p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,v_normalized,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
  v_sale_id := (v_result->>'venta_id')::bigint;
  IF (SELECT count(*) FROM public.detalle_ventas WHERE venta_id=v_sale_id) <> jsonb_array_length(v_snapshots) THEN
    RAISE EXCEPTION 'No se pudo asociar el snapshot de presentaciones';
  END IF;
  WITH saved AS (
    SELECT id,row_number() OVER(ORDER BY id) ordinal FROM public.detalle_ventas WHERE venta_id=v_sale_id
  ), snapshots AS (
    SELECT value snapshot,ordinality ordinal FROM jsonb_array_elements(v_snapshots) WITH ORDINALITY
  )
  UPDATE public.detalle_ventas d
    SET presentation_snapshot=s.snapshot,
        stock_scale_snapshot=COALESCE((s.snapshot->>'storage_scale')::integer,1)
    FROM saved x JOIN snapshots s USING(ordinal)
    WHERE d.id=x.id AND s.snapshot<>'null'::jsonb;

  UPDATE public.inventario_movimientos m
    SET stock_scale_snapshot=COALESCE((src.snapshot->>'storage_scale')::integer,1),
        salida_und=COALESCE(src.snapshot->>'base_label',m.salida_und),
        unidad_base_snapshot=COALESCE(src.snapshot->>'base_label',m.unidad_base_snapshot)
    FROM (
      SELECT (input.value->>'producto_id')::bigint product_id,saved.value snapshot
      FROM jsonb_array_elements(p_detalles) WITH ORDINALITY input(value,ordinal)
      JOIN jsonb_array_elements(v_snapshots) WITH ORDINALITY saved(value,ordinal) USING(ordinal)
      WHERE saved.value<>'null'::jsonb
    ) src
    WHERE m.request_id=p_request_id AND m.producto_id=src.product_id AND m.tipo='SALIDA';
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._product_unit_storage_scale(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._validate_product_unit_profile_v2(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v2(bigint,bigint,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v2(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v2(bigint,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v2(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;

COMMIT;
