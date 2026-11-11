-- 2D-H DEV: canonicalize service/bundle tipo_venta values.
-- productos_tipo_venta_canonical_check permits uppercase UNIDAD/CAJA/etc;
-- both legacy service normalization triggers wrote lowercase 'unidad',
-- causing valid save_service_v1 INSERT/UPDATE to fail SQLSTATE 23514.
-- Preserve item_type=service/bundle, tenant enforcement and all other guards.
-- Normalize SQL to LF to satisfy the GitHub CI no-worktree-drift gate.
CREATE OR REPLACE FUNCTION private.normalize_catalog_item_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_target_type text:=COALESCE(NULLIF(btrim(NEW.item_type),''),'stock_product');
  v_org uuid:=COALESCE(private.current_organization_id(),NEW.organization_id);
BEGIN
  -- Compatibilidad con writers legacy de servicios.
  IF COALESCE(NEW.es_servicio,false)
     AND (TG_OP='INSERT' OR OLD.es_servicio IS DISTINCT FROM NEW.es_servicio)
     AND v_target_type='stock_product' THEN
    v_target_type:='service';
  END IF;

  IF v_target_type NOT IN ('stock_product','non_stock_product','service','bundle') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported catalog item type';
  END IF;

  IF TG_OP='UPDATE' AND v_target_type IS DISTINCT FROM OLD.item_type THEN
    IF OLD.item_type='stock_product' AND v_target_type<>'stock_product' THEN
      IF EXISTS(
        SELECT 1 FROM public.inventario_almacen ia
        WHERE ia.organization_id=v_org AND ia.producto_id=OLD.id AND COALESCE(ia.cantidad,0)<>0
      ) OR EXISTS(
        SELECT 1 FROM public.inventory_lots l
        WHERE l.organization_id=v_org AND l.product_id=OLD.id AND l.base_quantity>0
      ) OR EXISTS(
        SELECT 1 FROM public.inventory_serials s
        WHERE s.organization_id=v_org AND s.product_id=OLD.id AND s.status='in_stock'
      ) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot convert a stocked item to a non-stock catalog type';
      END IF;
    END IF;

    IF OLD.item_type='bundle' AND v_target_type<>'bundle'
       AND EXISTS(
         SELECT 1 FROM public.bundle_components bc
         WHERE bc.organization_id=v_org AND bc.bundle_product_id=OLD.id
       ) THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Remove bundle components before changing bundle item type';
    END IF;
  END IF;

  NEW.item_type:=v_target_type;
  NEW.es_servicio:=(v_target_type='service');

  IF v_target_type IN ('non_stock_product','service','bundle') THEN
    NEW.permitir_sin_stock:=true;
    NEW.stock_minimo:=0;
  END IF;
  IF v_target_type='service' THEN
    NEW.unidad_medida:='Servicios';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='UNIDAD';
  ELSIF v_target_type='bundle' THEN
    NEW.unidad_medida:='Unidad';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='UNIDAD';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public._service_normalize_product_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  IF coalesce(NEW.es_servicio,false) THEN
    NEW.unidad_medida:='Servicios';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='UNIDAD';
    NEW.permitir_sin_stock:=true;
    NEW.stock_minimo:=0;
  END IF;
  RETURN NEW;
END;
$function$;
