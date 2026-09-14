BEGIN;

CREATE OR REPLACE FUNCTION public._resolve_serial_numbers_v1(
  p_product_id bigint,
  p_warehouse_id bigint,
  p_quantity integer,
  p_requested jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_result jsonb:='[]'::jsonb;
  v_serial text;
  v_count integer:=0;
BEGIN
  IF p_product_id IS NULL OR p_product_id<=0 OR p_warehouse_id IS NULL
     OR p_warehouse_id<=0 OR p_quantity IS NULL OR p_quantity<=0 THEN
    RAISE EXCEPTION 'Solicitud de series inválida' USING ERRCODE='22023';
  END IF;

  IF p_requested IS NOT NULL AND jsonb_typeof(p_requested)='array'
     AND jsonb_array_length(p_requested)>0 THEN
    IF jsonb_array_length(p_requested)<>p_quantity THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad' USING ERRCODE='23514';
    END IF;
    FOR v_serial IN
      SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_requested)
    LOOP
      IF v_serial='' OR EXISTS(
        SELECT 1 FROM jsonb_array_elements_text(v_result) AS e(value)
        WHERE lower(e.value)=lower(v_serial)
      ) THEN
        RAISE EXCEPTION 'Serie inválida o repetida' USING ERRCODE='22023';
      END IF;
      PERFORM 1 FROM public.inventory_serials
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id
        AND serial_number=v_serial AND status='in_stock'
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible',v_serial USING ERRCODE='23514';
      END IF;
      v_result:=v_result||jsonb_build_array(v_serial);
      v_count:=v_count+1;
    END LOOP;
  ELSE
    FOR v_serial IN
      SELECT s.serial_number
      FROM public.inventory_serials s
      WHERE s.product_id=p_product_id AND s.warehouse_id=p_warehouse_id
        AND s.status='in_stock'
      ORDER BY s.created_at,s.id
      LIMIT p_quantity
      FOR UPDATE
    LOOP
      v_result:=v_result||jsonb_build_array(v_serial);
      v_count:=v_count+1;
    END LOOP;
    IF v_count<>p_quantity THEN
      RAISE EXCEPTION 'Stock seriado insuficiente en el almacén' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._resolve_serial_numbers_v1(bigint,bigint,integer,jsonb)
  FROM PUBLIC,anon,authenticated;

COMMIT;
