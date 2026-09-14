BEGIN;

-- Corrected profile writer. v2 remains in history but clients use v3 so the
-- existence decision cannot be overwritten by subsequent SQL statements.
CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v3(
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
  v_exists boolean := false;
  v_old_scale integer := 1;
  v_new_scale integer;
  v_divisor integer;
  v_ratio numeric;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede editar presentaciones';
  END IF;
  IF p_product_id IS NULL OR p_product_id <= 0
     OR p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'Producto o revisión inválidos';
  END IF;
  PERFORM public._validate_product_unit_profile_v2(p_profile);
  v_new_scale := public._product_unit_storage_scale(p_profile);

  PERFORM 1 FROM public.productos p
   WHERE p.id=p_product_id AND COALESCE(p.activo,true) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;

  SELECT * INTO v_current
  FROM public.product_unit_profiles
  WHERE product_id=p_product_id FOR UPDATE;
  v_exists := FOUND;

  IF v_exists THEN
    IF v_current.revision <> p_expected_revision THEN
      RAISE EXCEPTION USING ERRCODE='40001',
        MESSAGE='La configuración cambió en otro equipo';
    END IF;
    IF v_current.profile->>'base_code' <> p_profile->>'base_code' THEN
      RAISE EXCEPTION 'La unidad base no puede sustituirse sin una conversión explícita';
    END IF;
    v_old_scale := public._product_unit_storage_scale(v_current.profile);
  ELSIF p_expected_revision <> 0 THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='La configuración ya no existe';
  END IF;

  IF v_new_scale <> v_old_scale THEN
    PERFORM 1 FROM public.inventario_almacen
      WHERE producto_id=p_product_id FOR UPDATE;

    IF v_new_scale > v_old_scale THEN
      v_ratio := v_new_scale::numeric / v_old_scale::numeric;
      IF EXISTS (
        SELECT 1 FROM public.inventario_almacen
        WHERE producto_id=p_product_id
          AND abs(cantidad::numeric*v_ratio) > 2147483647
      ) OR EXISTS (
        SELECT 1 FROM public.detalle_ventas
        WHERE producto_id=p_product_id
          AND abs(COALESCE(piezas_reales,0)::numeric*v_ratio) > 2147483647
      ) THEN
        RAISE EXCEPTION 'La precisión solicitada excede el rango del inventario';
      END IF;
      UPDATE public.inventario_almacen
        SET cantidad=(cantidad::numeric*v_ratio)::integer
        WHERE producto_id=p_product_id;
      UPDATE public.detalle_ventas
        SET piezas_reales=(COALESCE(piezas_reales,0)::numeric*v_ratio)::integer,
            precio_unitario=CASE WHEN precio_unitario IS NULL THEN NULL
              ELSE precio_unitario/v_ratio END,
            stock_scale_snapshot=v_new_scale
        WHERE producto_id=p_product_id;
      UPDATE public.detalle_cotizaciones
        SET piezas_reales=(COALESCE(piezas_reales,0)::numeric*v_ratio)::integer,
            precio_unitario=CASE WHEN precio_unitario IS NULL THEN NULL
              ELSE precio_unitario/v_ratio END,
            stock_scale_snapshot=v_new_scale
        WHERE producto_id=p_product_id;
      IF to_regclass('public.notas_credito_detalles') IS NOT NULL THEN
        UPDATE public.notas_credito_detalles
          SET piezas_reales=(COALESCE(piezas_reales,0)::numeric*v_ratio)::integer
          WHERE producto_id=p_product_id;
      END IF;
    ELSE
      v_divisor := v_old_scale / v_new_scale;
      IF v_divisor <= 0 OR v_old_scale % v_new_scale <> 0 THEN
        RAISE EXCEPTION 'Conversión de precisión no soportada';
      END IF;
      IF EXISTS (SELECT 1 FROM public.inventario_almacen
                 WHERE producto_id=p_product_id AND cantidad % v_divisor <> 0)
         OR EXISTS (SELECT 1 FROM public.detalle_ventas
                    WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % v_divisor <> 0)
         OR EXISTS (SELECT 1 FROM public.detalle_cotizaciones
                    WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % v_divisor <> 0) THEN
        RAISE EXCEPTION 'No se puede reducir la precisión sin perder cantidades existentes';
      END IF;
      IF to_regclass('public.notas_credito_detalles') IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.notas_credito_detalles
                     WHERE producto_id=p_product_id AND COALESCE(piezas_reales,0) % v_divisor <> 0) THEN
        RAISE EXCEPTION 'Notas de crédito existentes impiden reducir la precisión';
      END IF;
      UPDATE public.inventario_almacen
        SET cantidad=cantidad/v_divisor WHERE producto_id=p_product_id;
      UPDATE public.detalle_ventas
        SET piezas_reales=COALESCE(piezas_reales,0)/v_divisor,
            precio_unitario=CASE WHEN precio_unitario IS NULL THEN NULL
              ELSE precio_unitario*v_divisor END,
            stock_scale_snapshot=v_new_scale
        WHERE producto_id=p_product_id;
      UPDATE public.detalle_cotizaciones
        SET piezas_reales=COALESCE(piezas_reales,0)/v_divisor,
            precio_unitario=CASE WHEN precio_unitario IS NULL THEN NULL
              ELSE precio_unitario*v_divisor END,
            stock_scale_snapshot=v_new_scale
        WHERE producto_id=p_product_id;
      IF to_regclass('public.notas_credito_detalles') IS NOT NULL THEN
        UPDATE public.notas_credito_detalles
          SET piezas_reales=COALESCE(piezas_reales,0)/v_divisor
          WHERE producto_id=p_product_id;
      END IF;
    END IF;
  END IF;

  IF v_exists THEN
    UPDATE public.product_unit_profiles
      SET profile=p_profile,revision=revision+1,updated_at=now()
      WHERE product_id=p_product_id RETURNING * INTO v_saved;
  ELSE
    INSERT INTO public.product_unit_profiles(product_id,revision,profile)
      VALUES(p_product_id,1,p_profile) RETURNING * INTO v_saved;
  END IF;

  RETURN jsonb_build_object(
    'revision',v_saved.revision,
    'profile',v_saved.profile,
    'storage_scale',v_new_scale
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.guardar_cotizacion_with_units_v2(
  p_request_id uuid,
  p_cliente_id bigint,
  p_total numeric,
  p_fecha timestamptz,
  p_observaciones text,
  p_validez_dias integer,
  p_detalles jsonb
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
  v_factor numeric;
  v_base numeric;
  v_scale integer;
  v_stored numeric;
  v_price numeric;
  v_subtotal numeric;
  v_base_label text;
  v_legacy_unit text;
  v_result jsonb;
  v_quote_id bigint;
BEGIN
  IF NOT public.app_empleado_activo() THEN RAISE EXCEPTION 'Acceso denegado'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request_id es obligatorio'; END IF;
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array'
     OR jsonb_array_length(p_detalles)=0 THEN
    RAISE EXCEPTION 'La cotización requiere detalles';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  SELECT id INTO v_quote_id FROM public.cotizaciones WHERE request_id=p_request_id;
  IF FOUND THEN
    RETURN jsonb_build_object('success',true,'idempotent',true,'cotizacion_id',v_quote_id);
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    IF NOT (v_detail ? 'unit_profile_revision') THEN
      v_normalized:=v_normalized||jsonb_build_array(v_detail);
      v_snapshots:=v_snapshots||jsonb_build_array(NULL);
      CONTINUE;
    END IF;
    SELECT lower(COALESCE(tipo_venta,'')) INTO v_product_type
      FROM public.productos
      WHERE id=(v_detail->>'producto_id')::bigint AND COALESCE(activo,true) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;
    SELECT * INTO v_profile FROM public.product_unit_profiles
      WHERE product_id=(v_detail->>'producto_id')::bigint FOR SHARE;
    IF NOT FOUND OR v_profile.revision<>(v_detail->>'unit_profile_revision')::bigint THEN
      RAISE EXCEPTION 'Las presentaciones del producto cambiaron; vuelve a seleccionarlo';
    END IF;
    PERFORM public._validate_product_unit_profile_v2(v_profile.profile);
    v_scale:=public._product_unit_storage_scale(v_profile.profile);
    SELECT value INTO v_presentation
      FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code'=v_detail->>'tipo_unidad';
    IF v_presentation IS NULL THEN RAISE EXCEPTION 'La presentación ya no existe'; END IF;
    SELECT value->>'singular' INTO v_base_label
      FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code'=v_profile.profile->>'base_code';
    v_quantity:=NULLIF(v_detail->>'cantidad','')::numeric;
    v_factor:=(v_presentation->>'factor')::numeric;
    v_base:=v_quantity*v_factor;
    v_stored:=v_base*v_scale;
    v_subtotal:=NULLIF(v_detail->>'subtotal','')::numeric;
    v_price:=NULLIF(v_detail->>'precio_unitario_comercial','')::numeric;
    IF v_quantity IS NULL OR v_quantity<=0 OR v_stored<>trunc(v_stored)
       OR v_stored<=0 OR v_stored>2147483647
       OR NULLIF(v_detail->>'piezas_reales','')::numeric IS DISTINCT FROM v_stored
       OR COALESCE(NULLIF(v_detail->>'stock_scale','')::integer,v_scale)<>v_scale
       OR v_subtotal IS NULL OR v_subtotal<0 OR v_price IS NULL OR v_price<0
       OR abs(v_subtotal-v_quantity*v_price)>0.02 THEN
      RAISE EXCEPTION 'Cantidad, escala o precio comercial inconsistente';
    END IF;
    v_legacy_unit:=CASE
      WHEN v_product_type IN ('paquetes','paquete','caja_paquetes') THEN 'paquete'
      WHEN v_product_type IN ('solo_cajas','caja') THEN 'caja'
      ELSE 'unidad' END;
    v_normalized:=v_normalized||jsonb_build_array(v_detail||jsonb_build_object(
      'cantidad',v_stored::integer,
      'piezas_reales',v_stored::integer,
      'tipo_unidad',v_legacy_unit,
      'precio_unitario',round(v_subtotal/v_stored,4),
      'precio_unitario_comercial',round(v_subtotal/v_stored,4)
    ));
    v_snapshots:=v_snapshots||jsonb_build_array(jsonb_build_object(
      'schema_version',2,'code',v_presentation->>'code',
      'singular',v_presentation->>'singular','plural',v_presentation->>'plural',
      'factor',v_factor,'quantity',v_quantity,'commercial_price',v_price,
      'base_quantity',v_base,'base_code',v_profile.profile->>'base_code',
      'base_label',v_base_label,'revision',v_profile.revision,
      'storage_scale',v_scale,'profile',v_profile.profile
    ));
  END LOOP;

  v_result:=public.guardar_cotizacion_v2(
    p_request_id,p_cliente_id,p_total,p_fecha,p_observaciones,p_validez_dias,v_normalized
  );
  v_quote_id:=(v_result->>'cotizacion_id')::bigint;
  IF v_quote_id IS NULL OR (SELECT count(*) FROM public.detalle_cotizaciones
      WHERE cotizacion_id=v_quote_id)<>jsonb_array_length(v_snapshots) THEN
    RAISE EXCEPTION 'No se pudo asociar el snapshot de presentaciones';
  END IF;
  WITH saved AS (
    SELECT id,row_number() OVER(ORDER BY id) ordinal
      FROM public.detalle_cotizaciones WHERE cotizacion_id=v_quote_id
  ), snapshots AS (
    SELECT value snapshot,ordinality ordinal
      FROM jsonb_array_elements(v_snapshots) WITH ORDINALITY
  )
  UPDATE public.detalle_cotizaciones d
    SET presentation_snapshot=s.snapshot,
        stock_scale_snapshot=COALESCE((s.snapshot->>'storage_scale')::integer,1)
    FROM saved x JOIN snapshots s USING(ordinal)
    WHERE d.id=x.id AND s.snapshot<>'null'::jsonb;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_product_unit_profile_v3(bigint,bigint,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v3(bigint,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamptz,text,integer,jsonb) TO authenticated;

COMMIT;
