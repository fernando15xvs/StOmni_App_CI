-- Recepciones de órdenes de compra compatibles con lotes/series.
-- Aditiva: conserva receive_purchase_order_v1 para clientes antiguos.
BEGIN;

CREATE OR REPLACE FUNCTION public.receive_purchase_order_v2(
  p_request_id uuid,
  p_purchase_order_id bigint,
  p_received_at timestamptz,
  p_document text,
  p_notes text,
  p_lines jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_order public.purchase_orders%ROWTYPE;
  v_receipt_id bigint;
  v_existing_order_id bigint;
  v_line jsonb;
  v_order_line public.purchase_order_lines%ROWTYPE;
  v_product public.productos%ROWTYPE;
  v_quantity numeric;
  v_pending numeric;
  v_allocations jsonb;
  v_line_request uuid;
  v_active_mode text;
BEGIN
  IF NOT public.app_tiene_permiso('purchases.manage')
     OR NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para recibir compras' USING ERRCODE='42501';
  END IF;
  IF p_request_id IS NULL OR p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
     OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'Recepción de compra inválida' USING ERRCODE='22023';
  END IF;

  SELECT r.purchase_order_id INTO v_existing_order_id
  FROM public.purchase_receipts r WHERE r.request_id=p_request_id;
  IF v_existing_order_id IS NOT NULL THEN
    IF v_existing_order_id<>p_purchase_order_id THEN
      RAISE EXCEPTION 'El request_id pertenece a otra orden' USING ERRCODE='23505';
    END IF;
    RETURN public._purchase_order_json(v_existing_order_id);
  END IF;

  SELECT * INTO v_order FROM public.purchase_orders
  WHERE id=p_purchase_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Orden de compra inexistente' USING ERRCODE='P0002'; END IF;
  IF v_order.status NOT IN ('ordered','partially_received') THEN
    RAISE EXCEPTION 'La orden no admite recepciones en su estado actual' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.purchase_receipts(request_id,purchase_order_id,received_at,document,notes)
  VALUES(p_request_id,p_purchase_order_id,coalesce(p_received_at,now()),
         coalesce(trim(p_document),''),coalesce(trim(p_notes),''))
  RETURNING id INTO v_receipt_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_order_line FROM public.purchase_order_lines
    WHERE id=NULLIF(v_line->>'purchase_order_line_id','')::bigint
      AND purchase_order_id=p_purchase_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Línea de compra inexistente' USING ERRCODE='P0002'; END IF;

    v_quantity:=NULLIF(v_line->>'base_quantity','')::numeric;
    v_pending:=v_order_line.ordered_base_quantity-v_order_line.received_base_quantity;
    IF v_quantity IS NULL OR v_quantity<=0 OR v_quantity>v_pending THEN
      RAISE EXCEPTION 'Cantidad recibida excede lo pendiente' USING ERRCODE='23514';
    END IF;
    PERFORM public._visible_base_to_stored(v_order_line.product_id,v_quantity);

    INSERT INTO public.purchase_receipt_lines(purchase_receipt_id,purchase_order_line_id,base_quantity)
    VALUES(v_receipt_id,v_order_line.id,v_quantity);

    SELECT * INTO v_product FROM public.productos WHERE id=v_order_line.product_id;
    v_active_mode:=public._active_traceability_mode_v1(v_order_line.product_id);
    v_allocations:=coalesce(v_line->'allocations','[]'::jsonb);

    -- UUID estable por recepción + línea. Una transacción fallida revierte todo;
    -- un retry confirmado retorna arriba por purchase_receipts.request_id.
    v_line_request:=(md5(p_request_id::text || ':' || v_order_line.id::text))::uuid;

    IF v_active_mode IN ('lot','serial') THEN
      IF jsonb_typeof(v_allocations)<>'array' OR jsonb_array_length(v_allocations)=0 THEN
        RAISE EXCEPTION 'La línea % requiere asignación de trazabilidad',v_order_line.id
          USING ERRCODE='23514';
      END IF;
      PERFORM public.register_traceable_merchandise_receipt_v1(
        v_line_request,v_order_line.product_id,v_order.warehouse_id,v_quantity,
        coalesce(p_received_at,now()),'Compra',coalesce(trim(p_document),''),
        v_order.supplier_id,
        'Recepción OC #' || p_purchase_order_id::text ||
          CASE WHEN nullif(trim(coalesce(p_notes,'')),'') IS NULL THEN '' ELSE ' · ' || trim(p_notes) END,
        v_order_line.unit_cost,coalesce(v_product.precio_unidad,0),
        coalesce(v_product.precio_caja,0),
        coalesce(v_product.precio_caja,0)*greatest(coalesce(v_product.cantidad_por_caja,1),1),
        v_allocations
      );
    ELSE
      IF jsonb_array_length(v_allocations)>0 THEN
        RAISE EXCEPTION 'La línea % no tiene trazabilidad activa',v_order_line.id USING ERRCODE='22023';
      END IF;
      PERFORM public.registrar_ingreso_mercaderia_scaled_v2(
        v_line_request,v_order_line.product_id,coalesce(p_received_at,now()),
        'Compra',coalesce(trim(p_document),''),v_order.supplier_id,
        'Recepción OC #' || p_purchase_order_id::text ||
          CASE WHEN nullif(trim(coalesce(p_notes,'')),'') IS NULL THEN '' ELSE ' · ' || trim(p_notes) END,
        jsonb_build_array(jsonb_build_object('almacen_id',v_order.warehouse_id,'cantidad_base',v_quantity)),
        v_order_line.unit_cost,coalesce(v_product.precio_unidad,0),
        coalesce(v_product.precio_caja,0),
        coalesce(v_product.precio_caja,0)*greatest(coalesce(v_product.cantidad_por_caja,1),1)
      );
    END IF;

    UPDATE public.purchase_order_lines
    SET received_base_quantity=received_base_quantity+v_quantity
    WHERE id=v_order_line.id;
  END LOOP;

  UPDATE public.purchase_orders o
  SET status=CASE WHEN NOT EXISTS(
        SELECT 1 FROM public.purchase_order_lines l
        WHERE l.purchase_order_id=o.id
          AND l.received_base_quantity<l.ordered_base_quantity
      ) THEN 'received' ELSE 'partially_received' END,
      updated_at=now()
  WHERE o.id=p_purchase_order_id;

  RETURN public._purchase_order_json(p_purchase_order_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)
  TO authenticated;

COMMIT;
