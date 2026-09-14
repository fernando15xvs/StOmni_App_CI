-- Servicios reutilizan catálogo/pricing/venta/documentos, pero nunca inventario.
BEGIN;

ALTER TABLE public.productos
  ADD COLUMN es_servicio boolean NOT NULL DEFAULT false;
ALTER TABLE public.business_capabilities
  ADD COLUMN services boolean NOT NULL DEFAULT false;

-- El esquema histórico de productos no tiene una columna descripcion estable.
-- La metadata exclusiva de servicios vive separada para no alterar contratos
-- legacy del catálogo físico.
CREATE TABLE public.service_metadata (
  product_id bigint PRIMARY KEY REFERENCES public.productos(id) ON DELETE CASCADE,
  description text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT service_metadata_description_length CHECK (length(description) <= 2000)
);
ALTER TABLE public.service_metadata ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.service_metadata FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public._business_services_enabled()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
  SELECT coalesce((SELECT services FROM public.business_capabilities WHERE business_id=1),false);
$function$;

-- Un servicio nunca puede adquirir semántica inventariable aunque un cliente
-- antiguo intente editarlo mediante el writer genérico de productos.
CREATE OR REPLACE FUNCTION public._service_normalize_product_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF coalesce(NEW.es_servicio,false) THEN
    NEW.unidad_medida:='Servicios';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='unidad';
    NEW.permitir_sin_stock:=true;
    NEW.stock_minimo:=0;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER service_product_invariants
BEFORE INSERT OR UPDATE ON public.productos
FOR EACH ROW EXECUTE FUNCTION public._service_normalize_product_v1();

CREATE OR REPLACE FUNCTION public._service_zero_inventory_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_service boolean;
BEGIN
  SELECT coalesce(es_servicio,false) INTO v_service
  FROM public.productos WHERE id=NEW.producto_id;
  IF v_service THEN NEW.cantidad:=0; END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER service_inventory_always_zero
BEFORE INSERT OR UPDATE OF cantidad ON public.inventario_almacen
FOR EACH ROW EXECUTE FUNCTION public._service_zero_inventory_v1();

CREATE OR REPLACE FUNCTION public._service_skip_kardex_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF EXISTS(SELECT 1 FROM public.productos p WHERE p.id=NEW.producto_id AND p.es_servicio) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER service_no_inventory_movements
BEFORE INSERT ON public.inventario_movimientos
FOR EACH ROW EXECUTE FUNCTION public._service_skip_kardex_v1();

CREATE OR REPLACE FUNCTION public._service_block_purchase_line_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF EXISTS(SELECT 1 FROM public.productos p WHERE p.id=NEW.product_id AND p.es_servicio) THEN
    RAISE EXCEPTION 'Los servicios no se reciben como inventario' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER service_not_purchase_inventory
BEFORE INSERT OR UPDATE OF product_id ON public.purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION public._service_block_purchase_line_v1();

CREATE OR REPLACE FUNCTION public._service_block_traceability_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NEW.mode<>'none' AND EXISTS(
    SELECT 1 FROM public.productos p WHERE p.id=NEW.product_id AND p.es_servicio
  ) THEN
    RAISE EXCEPTION 'Un servicio no puede usar lotes ni series' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER service_not_traceable
BEFORE INSERT OR UPDATE OF mode ON public.product_traceability_configs
FOR EACH ROW EXECUTE FUNCTION public._service_block_traceability_v1();

CREATE OR REPLACE FUNCTION public._service_json_v1(p_product_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
  SELECT jsonb_build_object(
    'id',p.id,'code',coalesce(p.codigo,''),'name',coalesce(p.nombre,''),
    'description',coalesce(m.description,''),'unit_price',coalesce(p.precio_unidad,0),
    'purchase_price',coalesce(p.precio_compra,0),'active',coalesce(p.activo,true)
  )
  FROM public.productos p
  LEFT JOIN public.service_metadata m ON m.product_id=p.id
  WHERE p.id=p_product_id AND p.es_servicio;
$function$;

CREATE OR REPLACE FUNCTION public.list_services_v1(p_include_inactive boolean DEFAULT false)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
  SELECT public._service_json_v1(p.id)
  FROM public.productos p
  WHERE public.app_empleado_activo()
    AND public._business_services_enabled()
    AND p.es_servicio
    AND (coalesce(p_include_inactive,false) OR coalesce(p.activo,true))
  ORDER BY p.nombre,p.id;
$function$;

CREATE OR REPLACE FUNCTION public.save_service_v1(
  p_service_id bigint,
  p_code text,
  p_name text,
  p_description text,
  p_unit_price numeric,
  p_purchase_price numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_id bigint;
  v_code text:=upper(trim(coalesce(p_code,'')));
  v_name text:=trim(coalesce(p_name,''));
  v_description text:=trim(coalesce(p_description,''));
BEGIN
  IF NOT public._business_services_enabled() THEN
    RAISE EXCEPTION 'Los servicios están deshabilitados' USING ERRCODE='23514';
  END IF;
  IF p_service_id IS NULL THEN
    IF NOT public.app_tiene_permiso('products.create') THEN
      RAISE EXCEPTION 'No autorizado para crear servicios' USING ERRCODE='42501';
    END IF;
  ELSE
    IF NOT public.app_tiene_permiso('products.update') THEN
      RAISE EXCEPTION 'No autorizado para editar servicios' USING ERRCODE='42501';
    END IF;
  END IF;
  IF NOT public.app_tiene_permiso('products.change_price') THEN
    RAISE EXCEPTION 'No autorizado para cambiar precios' USING ERRCODE='42501';
  END IF;
  IF v_code='' OR length(v_code)>80 OR v_name='' OR length(v_name)>200
     OR length(v_description)>2000
     OR p_unit_price IS NULL OR p_unit_price<0
     OR p_purchase_price IS NULL OR p_purchase_price<0 THEN
    RAISE EXCEPTION 'Servicio inválido' USING ERRCODE='22023';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.productos p
    WHERE upper(trim(coalesce(p.codigo,'')))=v_code
      AND (p_service_id IS NULL OR p.id<>p_service_id)
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto o servicio con ese código' USING ERRCODE='23505';
  END IF;

  IF p_service_id IS NULL THEN
    INSERT INTO public.productos(
      codigo,nombre,precio_unidad,precio_caja,precio_compra,
      unidad_medida,cantidad_por_caja,tipo_venta,permitir_sin_stock,
      stock_minimo,es_servicio,activo
    ) VALUES(
      v_code,v_name,p_unit_price,p_unit_price,p_purchase_price,
      'Servicios',1,'unidad',true,0,true,true
    ) RETURNING id INTO v_id;
  ELSE
    PERFORM 1 FROM public.productos WHERE id=p_service_id AND es_servicio FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Servicio inexistente' USING ERRCODE='P0002'; END IF;
    UPDATE public.productos SET
      codigo=v_code,nombre=v_name,
      precio_unidad=p_unit_price,precio_caja=p_unit_price,precio_compra=p_purchase_price,
      unidad_medida='Servicios',cantidad_por_caja=1,tipo_venta='unidad',
      permitir_sin_stock=true,stock_minimo=0,es_servicio=true,activo=true
    WHERE id=p_service_id;
    v_id:=p_service_id;
  END IF;

  INSERT INTO public.service_metadata(product_id,description,updated_at)
  VALUES(v_id,v_description,now())
  ON CONFLICT(product_id) DO UPDATE SET
    description=EXCLUDED.description,
    updated_at=EXCLUDED.updated_at;

  INSERT INTO public.inventario_almacen(producto_id,almacen_id,cantidad)
  SELECT v_id,a.id,0 FROM public.almacenes a WHERE coalesce(a.activo,true)
  ON CONFLICT(producto_id,almacen_id) DO UPDATE SET cantidad=0;

  RETURN public._service_json_v1(v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_service_v1(p_service_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('products.update') THEN
    RAISE EXCEPTION 'No autorizado para desactivar servicios' USING ERRCODE='42501';
  END IF;
  UPDATE public.productos SET activo=false
  WHERE id=p_service_id AND es_servicio;
  IF NOT FOUND THEN RAISE EXCEPTION 'Servicio inexistente' USING ERRCODE='P0002'; END IF;
END;
$function$;

-- Perfil de capacidades final de este bloque. Services continúa false hasta que
-- el administrador lo active explícitamente.
CREATE OR REPLACE FUNCTION public.get_business_profile_v1()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'No autorizado para consultar el negocio' USING ERRCODE='42501';
  END IF;
  SELECT jsonb_build_object(
    'business_id',c.id::text,
    'display_name',COALESCE(NULLIF(c.nombre_comercial,''),c.razon_social,''),
    'revision',b.revision,'supports_capability_settings',true,
    'capabilities',jsonb_build_object(
      'inventory_enabled',true,'multiple_warehouses',true,
      'credit_sales',b.credit_sales,'electronic_invoicing',b.electronic_invoicing,
      'supplier_management',true,'purchase_management',b.purchase_management,
      'lot_tracking',b.lot_tracking,'expiry_tracking',b.expiry_tracking,
      'variants',b.variants,'services',b.services,
      'serial_number_tracking',b.serial_number_tracking
    )
  ) INTO v_result
  FROM public.configuracion_negocio c
  JOIN public.business_capabilities b ON b.business_id=c.id WHERE c.id=1;
  IF v_result IS NULL THEN RAISE EXCEPTION 'Configura primero el negocio y sus capacidades'; END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_business_capabilities_v1(
  p_expected_revision bigint,p_capabilities jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_current public.business_capabilities%ROWTYPE; v_lot boolean; v_expiry boolean; v_serial boolean;
BEGIN
  IF NOT public.app_tiene_permiso('business.configure') THEN
    RAISE EXCEPTION 'Solo el administrador configura capacidades' USING ERRCODE='42501';
  END IF;
  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities)<>'object'
     OR (p_capabilities-ARRAY['credit_sales','electronic_invoicing','purchase_management','variants','lot_tracking','expiry_tracking','serial_number_tracking','services'])
        IS DISTINCT FROM '{"inventory_enabled":true,"multiple_warehouses":true,"supplier_management":true}'::jsonb
     OR EXISTS(
       SELECT 1 FROM jsonb_each(p_capabilities) e
       WHERE e.key IN ('credit_sales','electronic_invoicing','purchase_management','variants','lot_tracking','expiry_tracking','serial_number_tracking','services')
         AND jsonb_typeof(e.value)<>'boolean'
     ) THEN
    RAISE EXCEPTION 'Capacidades no compatibles' USING ERRCODE='22023';
  END IF;
  v_lot:=(p_capabilities->>'lot_tracking')::boolean;
  v_expiry:=(p_capabilities->>'expiry_tracking')::boolean;
  v_serial:=(p_capabilities->>'serial_number_tracking')::boolean;
  IF v_expiry AND NOT v_lot THEN
    RAISE EXCEPTION 'El seguimiento de vencimientos requiere lotes' USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_current FROM public.business_capabilities WHERE business_id=1 FOR UPDATE;
  IF NOT FOUND OR p_expected_revision IS NULL OR p_expected_revision<>v_current.revision THEN
    RAISE EXCEPTION 'La configuración cambió. Recarga antes de guardar.' USING ERRCODE='40001';
  END IF;
  IF v_current.lot_tracking AND NOT v_lot AND EXISTS(SELECT 1 FROM public.inventory_lots WHERE base_quantity>0) THEN
    RAISE EXCEPTION 'No puedes desactivar lotes con stock por lote' USING ERRCODE='23514';
  END IF;
  IF v_current.serial_number_tracking AND NOT v_serial AND EXISTS(SELECT 1 FROM public.inventory_serials WHERE status='in_stock') THEN
    RAISE EXCEPTION 'No puedes desactivar series con stock seriado' USING ERRCODE='23514';
  END IF;
  UPDATE public.business_capabilities SET
    credit_sales=(p_capabilities->>'credit_sales')::boolean,
    electronic_invoicing=(p_capabilities->>'electronic_invoicing')::boolean,
    purchase_management=(p_capabilities->>'purchase_management')::boolean,
    variants=(p_capabilities->>'variants')::boolean,
    lot_tracking=v_lot,expiry_tracking=v_expiry,serial_number_tracking=v_serial,
    services=(p_capabilities->>'services')::boolean,
    revision=revision+1,updated_at=now()
  WHERE business_id=1;
  RETURN public.get_business_profile_v1();
END;
$function$;

REVOKE ALL ON FUNCTION public._business_services_enabled() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_normalize_product_v1() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_zero_inventory_v1() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_skip_kardex_v1() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_block_purchase_line_v1() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_block_traceability_v1() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_json_v1(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.list_services_v1(boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.deactivate_service_v1(bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_services_v1(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_service_v1(bigint) TO authenticated;

COMMIT;
