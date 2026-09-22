BEGIN;

-- StOmni starts from a clean product contract. Historical migrations remain
-- immutable, but the effective schema accepts only canonical product codes.
CREATE OR REPLACE FUNCTION public._require_product_sale_type(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $function$
DECLARE
  v_value text := trim(coalesce(p_value, ''));
BEGIN
  IF p_value IS NULL OR p_value <> v_value OR p_value <> upper(p_value)
     OR v_value NOT IN (
       'UNIDAD','CAJA','PAQUETE','CAJA_PAQUETES','CAJA_UNIDADES'
     ) THEN
    RAISE EXCEPTION 'tipo_venta no canónico: %', coalesce(p_value, '<null>')
      USING ERRCODE='22023';
  END IF;
  RETURN v_value;
END;
$function$;

REVOKE ALL ON FUNCTION public._require_product_sale_type(text)
  FROM PUBLIC, anon, authenticated;

ALTER TABLE public.productos
  ALTER COLUMN tipo_venta DROP DEFAULT,
  ALTER COLUMN tipo_venta SET NOT NULL;

ALTER TABLE public.productos
  DROP CONSTRAINT IF EXISTS productos_tipo_venta_canonical_check;
ALTER TABLE public.productos
  ADD CONSTRAINT productos_tipo_venta_canonical_check
  CHECK (
    tipo_venta IN ('UNIDAD','CAJA','PAQUETE','CAJA_PAQUETES','CAJA_UNIDADES')
  );

COMMENT ON COLUMN public.productos.tipo_venta IS
  'Topología comercial canónica: UNIDAD, CAJA, PAQUETE, CAJA_PAQUETES o CAJA_UNIDADES. No acepta aliases.';
COMMENT ON COLUMN public.productos.cantidad_por_caja IS
  'Factor entero del empaque canónico. En modalidades mixtas convierte caja a unidad base; en CAJA/PAQUETE describe el contenido comercial.';

ALTER TABLE public.product_unit_profiles
  DROP CONSTRAINT IF EXISTS product_unit_profiles_schema_v2_check;
ALTER TABLE public.product_unit_profiles
  ADD CONSTRAINT product_unit_profiles_schema_v2_check
  CHECK (
    jsonb_typeof(profile->'schema_version') = 'number'
    AND (profile->>'schema_version')::numeric = 2
  );

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
  IF v_version <> 2 THEN RAISE EXCEPTION 'schema_version debe ser 2'; END IF;
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
  IF v_version <> 2 THEN RAISE EXCEPTION 'schema_version debe ser 2'; END IF;
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

CREATE OR REPLACE FUNCTION public.crear_producto_con_stock(
  p_request_id uuid,p_datos_producto jsonb,p_stocks jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_producto_id bigint;
  v_stock jsonb;
  v_almacen_id bigint;
  v_delta integer;
  v_codigo text;
  v_nombre text;
  v_tipo_venta text;
  v_unidad_medida text;
  v_proveedor_id bigint;
  v_stock_minimo integer;
  v_almacenes bigint[] := '{}';
  v_resultado jsonb;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Solo el administrador puede crear productos' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_inventory_request_scope(p_request_id);

  IF p_datos_producto IS NULL OR jsonb_typeof(p_datos_producto)<>'object'
     OR p_stocks IS NULL OR jsonb_typeof(p_stocks)<>'array' THEN
    RAISE EXCEPTION 'Datos de producto o stock inválidos' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || p_request_id::text,0));
  SELECT resultado INTO v_resultado
  FROM public.sys_processed_requests
  WHERE organization_id=v_organization_id AND request_id=p_request_id;
  IF FOUND THEN RETURN v_resultado; END IF;

  v_codigo:=upper(trim(coalesce(p_datos_producto->>'codigo','')));
  v_nombre:=trim(coalesce(p_datos_producto->>'nombre',''));
  v_tipo_venta:=public._require_product_sale_type(p_datos_producto->>'tipo_venta');
  v_proveedor_id:=nullif(p_datos_producto->>'proveedor_id','')::bigint;
  v_stock_minimo:=coalesce(nullif(p_datos_producto->>'stock_minimo','')::integer,0);

  IF v_codigo='' OR length(v_codigo)>50 OR v_codigo !~ '^[A-Z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Código de producto inválido' USING ERRCODE='22023';
  END IF;
  IF v_nombre='' THEN RAISE EXCEPTION 'El nombre del producto no puede estar vacío' USING ERRCODE='22023'; END IF;
  IF coalesce(nullif(p_datos_producto->>'cantidad_por_caja','')::integer,0)<1 OR v_stock_minimo<0 THEN
    RAISE EXCEPTION 'Configuración de empaque/stock inválida' USING ERRCODE='22023';
  END IF;
  IF coalesce(nullif(p_datos_producto->>'precio_unidad','')::numeric,0)<0
     OR coalesce(nullif(p_datos_producto->>'precio_caja','')::numeric,0)<0
     OR coalesce(nullif(p_datos_producto->>'precio_compra','')::numeric,0)<0 THEN
    RAISE EXCEPTION 'Los precios y costos no pueden ser negativos' USING ERRCODE='22023';
  END IF;
  PERFORM private.assert_supplier_in_current_organization(v_proveedor_id);

  IF EXISTS(
    SELECT 1 FROM public.productos
    WHERE organization_id=v_organization_id AND upper(trim(coalesce(codigo,'')))=v_codigo
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto con el código %',v_codigo USING ERRCODE='23505';
  END IF;

  v_unidad_medida:=CASE v_tipo_venta
    WHEN 'CAJA' THEN 'Cajas'
    WHEN 'PAQUETE' THEN 'Paquetes'
    WHEN 'CAJA_PAQUETES' THEN 'Paquetes'
    ELSE 'Unidades'
  END;
  INSERT INTO public.productos(
    codigo,nombre,precio_unidad,precio_caja,precio_compra,imagen_path,unidad_medida,
    cantidad_por_caja,proveedor_id,permitir_sin_stock,tipo_venta,stock_minimo
  ) VALUES(
    v_codigo,v_nombre,
    coalesce(nullif(p_datos_producto->>'precio_unidad','')::numeric,0),
    coalesce(nullif(p_datos_producto->>'precio_caja','')::numeric,0),
    coalesce(nullif(p_datos_producto->>'precio_compra','')::numeric,0),
    nullif(trim(coalesce(p_datos_producto->>'imagen_path','')),''),v_unidad_medida,
    (p_datos_producto->>'cantidad_por_caja')::integer,v_proveedor_id,
    coalesce(nullif(p_datos_producto->>'permitir_sin_stock','')::boolean,false),v_tipo_venta,v_stock_minimo
  ) RETURNING id INTO v_producto_id;

  FOR v_stock IN SELECT value FROM jsonb_array_elements(p_stocks) LOOP
    v_almacen_id:=nullif(v_stock->>'almacen_id','')::bigint;
    v_delta:=coalesce(nullif(v_stock->>'delta','')::integer,0);
    PERFORM private.assert_warehouse_in_current_organization(v_almacen_id);
    IF v_delta<0 THEN RAISE EXCEPTION 'El stock inicial no puede ser negativo' USING ERRCODE='22023'; END IF;
    IF v_almacen_id=ANY(v_almacenes) THEN RAISE EXCEPTION 'Almacén duplicado en stock inicial' USING ERRCODE='22023'; END IF;
    v_almacenes:=array_append(v_almacenes,v_almacen_id);
    IF v_delta>0 THEN
      PERFORM public._aplicar_movimiento_inventario_v2(
        p_producto_id:=v_producto_id,p_almacen_id:=v_almacen_id,p_delta:=v_delta,
        p_tipo_movimiento:='ENTRADA',
        p_motivo:=coalesce(nullif(trim(v_stock->>'motivo'),''),'Apertura de Inventario / Stock Inicial'),
        p_fecha:=now(),p_ingreso_costo:=coalesce(nullif(v_stock->>'ingreso_costo','')::numeric,0),
        p_ingreso_p_unit:=coalesce(nullif(v_stock->>'ingreso_p_unit','')::numeric,0),
        p_ingreso_p_caja:=nullif(v_stock->>'ingreso_p_caja','')::numeric,
        p_ingreso_p_c_comp:=nullif(v_stock->>'ingreso_p_c_comp','')::numeric,
        p_request_id:=p_request_id
      );
    END IF;
  END LOOP;

  v_resultado:=jsonb_build_object(
    'success',true,'producto_id',v_producto_id,'codigo',v_codigo,
    'tipo_venta',v_tipo_venta,'mensaje','Producto y stock creados con éxito'
  );
  INSERT INTO public.sys_processed_requests(request_id,producto_id,resultado)
  VALUES(p_request_id,v_producto_id,v_resultado);
  RETURN v_resultado;
END;
$$;

CREATE OR REPLACE FUNCTION public.actualizar_producto_seguro_v1(
  p_producto_id bigint,
  p_datos jsonb,
  p_actualizar_apertura boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_producto public.productos%ROWTYPE;
  v_actualizado public.productos%ROWTYPE;
  v_evaluacion jsonb;
  v_codigo text;
  v_nombre text;
  v_precio_unidad numeric;
  v_precio_caja numeric;
  v_precio_compra numeric;
  v_imagen_path text;
  v_unidad_medida text;
  v_cantidad_por_caja integer;
  v_proveedor_id bigint;
  v_permitir_sin_stock boolean;
  v_tipo_venta text;
  v_stock_minimo integer;
  v_proveedor_nombre text;
  v_unidad_base text;
  v_aperturas_actualizadas bigint := 0;
  v_clave_no_permitida text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Solo el administrador puede editar productos' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_product_in_current_organization(p_producto_id);

  IF p_datos IS NULL OR jsonb_typeof(p_datos)<>'object' THEN
    RAISE EXCEPTION 'Los datos del producto son inválidos' USING ERRCODE='22023';
  END IF;

  SELECT clave INTO v_clave_no_permitida
  FROM jsonb_object_keys(p_datos) AS k(clave)
  WHERE clave NOT IN (
    'codigo','nombre','precio_unidad','precio_caja','precio_compra','imagen_path',
    'cantidad_por_caja','proveedor_id','permitir_sin_stock',
    'tipo_venta','stock_minimo'
  )
  LIMIT 1;
  IF v_clave_no_permitida IS NOT NULL THEN
    RAISE EXCEPTION 'El campo % no puede modificarse mediante esta función',v_clave_no_permitida USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(p_producto_id);
  SELECT * INTO v_producto
  FROM public.productos
  WHERE organization_id=v_organization_id AND id=p_producto_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El producto no existe en la organización actual' USING ERRCODE='P0002'; END IF;

  v_codigo:=upper(trim(CASE WHEN p_datos?'codigo' THEN coalesce(p_datos->>'codigo','') ELSE coalesce(v_producto.codigo,'') END));
  v_nombre:=trim(CASE WHEN p_datos?'nombre' THEN coalesce(p_datos->>'nombre','') ELSE coalesce(v_producto.nombre,'') END);
  v_precio_unidad:=CASE WHEN p_datos?'precio_unidad' THEN coalesce(nullif(p_datos->>'precio_unidad','')::numeric,0) ELSE coalesce(v_producto.precio_unidad,0) END;
  v_precio_caja:=CASE WHEN p_datos?'precio_caja' THEN coalesce(nullif(p_datos->>'precio_caja','')::numeric,0) ELSE coalesce(v_producto.precio_caja,0) END;
  v_precio_compra:=CASE WHEN p_datos?'precio_compra' THEN coalesce(nullif(p_datos->>'precio_compra','')::numeric,0) ELSE coalesce(v_producto.precio_compra,0) END;
  v_imagen_path:=CASE WHEN p_datos?'imagen_path' THEN nullif(trim(coalesce(p_datos->>'imagen_path','')),'') ELSE v_producto.imagen_path END;
  v_cantidad_por_caja:=CASE WHEN p_datos?'cantidad_por_caja' THEN coalesce(nullif(p_datos->>'cantidad_por_caja','')::integer,0) ELSE coalesce(v_producto.cantidad_por_caja,0) END;
  v_proveedor_id:=CASE WHEN p_datos?'proveedor_id' THEN nullif(p_datos->>'proveedor_id','')::bigint ELSE v_producto.proveedor_id END;
  v_permitir_sin_stock:=CASE WHEN p_datos?'permitir_sin_stock' THEN coalesce(nullif(p_datos->>'permitir_sin_stock','')::boolean,false) ELSE coalesce(v_producto.permitir_sin_stock,false) END;
  v_tipo_venta:=public._require_product_sale_type(CASE WHEN p_datos?'tipo_venta' THEN p_datos->>'tipo_venta' ELSE v_producto.tipo_venta END);
  v_stock_minimo:=CASE WHEN p_datos?'stock_minimo' THEN coalesce(nullif(p_datos->>'stock_minimo','')::integer,0) ELSE coalesce(v_producto.stock_minimo,0) END;
  v_unidad_medida:=CASE v_tipo_venta
    WHEN 'CAJA' THEN 'Cajas'
    WHEN 'PAQUETE' THEN 'Paquetes'
    WHEN 'CAJA_PAQUETES' THEN 'Paquetes'
    ELSE 'Unidades'
  END;

  IF v_codigo='' OR length(v_codigo)>50 OR v_codigo !~ '^[A-Z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Código de producto inválido' USING ERRCODE='22023';
  END IF;
  IF v_nombre='' THEN RAISE EXCEPTION 'El nombre del producto no puede estar vacío' USING ERRCODE='22023'; END IF;
  IF v_precio_unidad<0 OR v_precio_caja<0 OR v_precio_compra<0 THEN RAISE EXCEPTION 'Los precios y costos no pueden ser negativos' USING ERRCODE='22023'; END IF;
  IF v_cantidad_por_caja<1 THEN RAISE EXCEPTION 'La cantidad contenida en el empaque debe ser al menos 1' USING ERRCODE='22023'; END IF;
  IF v_stock_minimo<0 THEN RAISE EXCEPTION 'El stock mínimo no puede ser negativo' USING ERRCODE='22023'; END IF;
  PERFORM private.assert_supplier_in_current_organization(v_proveedor_id);

  IF EXISTS (
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=v_organization_id
      AND p.id<>p_producto_id
      AND upper(trim(coalesce(p.codigo,'')))=v_codigo
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto con el código % en esta empresa',v_codigo USING ERRCODE='23505';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=v_organization_id
      AND p.id<>p_producto_id
      AND coalesce(p.activo,true)
      AND lower(trim(p.nombre))=lower(v_nombre)
      AND p.tipo_venta=v_tipo_venta
      AND p.proveedor_id IS NOT DISTINCT FROM v_proveedor_id
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto activo equivalente en esta empresa' USING ERRCODE='23505';
  END IF;

  IF p_actualizar_apertura THEN
    v_evaluacion:=public.evaluar_eliminacion_producto_v1(p_producto_id);
    IF coalesce((v_evaluacion->>'puede_actualizar_apertura')::boolean,false)=false THEN
      RAISE EXCEPTION 'Los movimientos de apertura no pueden modificarse porque el producto ya tiene historial operativo o referencias' USING ERRCODE='23514';
    END IF;
  END IF;

  UPDATE public.productos p SET
    codigo=v_codigo,nombre=v_nombre,precio_unidad=v_precio_unidad,precio_caja=v_precio_caja,
    precio_compra=v_precio_compra,imagen_path=v_imagen_path,unidad_medida=v_unidad_medida,
    cantidad_por_caja=v_cantidad_por_caja,proveedor_id=v_proveedor_id,
    permitir_sin_stock=v_permitir_sin_stock,tipo_venta=v_tipo_venta,stock_minimo=v_stock_minimo
  WHERE p.organization_id=v_organization_id AND p.id=p_producto_id
  RETURNING * INTO v_actualizado;

  IF p_actualizar_apertura THEN
    SELECT coalesce(pr.nombre,'Generico') INTO v_proveedor_nombre
    FROM public.productos p
    LEFT JOIN public.proveedores pr
      ON pr.organization_id=p.organization_id AND pr.id=p.proveedor_id
    WHERE p.organization_id=v_organization_id AND p.id=p_producto_id;

    v_unidad_base:=CASE v_tipo_venta
      WHEN 'CAJA' THEN 'Caja'
      WHEN 'PAQUETE' THEN 'Paquete'
      WHEN 'CAJA_PAQUETES' THEN 'Paquete'
      ELSE 'Unidad'
    END;
    UPDATE public.inventario_movimientos m SET
      producto_nombre=v_nombre,pcs=v_cantidad_por_caja,proveedor=v_proveedor_nombre,
      tipo_venta_snapshot=v_tipo_venta,unidad_base_snapshot=v_unidad_base,ingreso_und=v_unidad_base
    WHERE m.organization_id=v_organization_id
      AND m.producto_id=p_producto_id
      AND upper(trim(coalesce(m.tipo,''))) IN ('ENTRADA','INGRESO')
      AND upper(regexp_replace(trim(coalesce(m.observaciones,'')),'\s+',' ','g')) IN (
        'APERTURA DE INVENTARIO / STOCK INICIAL','APERTURA DE INVENTARIO','STOCK INICIAL'
      )
      AND m.venta_id IS NULL
      AND coalesce(m.salida_cant,0)=0;
    GET DIAGNOSTICS v_aperturas_actualizadas=ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'success',true,'producto_id',p_producto_id,'producto',to_jsonb(v_actualizado),
    'aperturas_actualizadas',v_aperturas_actualizadas,
    'mensaje',CASE WHEN v_aperturas_actualizadas>0 THEN 'Producto y movimientos de apertura actualizados.' ELSE 'Producto actualizado.' END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.save_service_v1(
  p_service_id bigint,p_code text,p_name text,p_description text,p_unit_price numeric,p_purchase_price numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_id bigint;
  v_code text:=upper(trim(coalesce(p_code,'')));
  v_name text:=trim(coalesce(p_name,''));
  v_description text:=trim(coalesce(p_description,''));
BEGIN
  IF NOT public._business_services_enabled() THEN
    RAISE EXCEPTION 'Los servicios están deshabilitados' USING ERRCODE='23514';
  END IF;
  IF p_service_id IS NULL THEN
    IF NOT public.app_tiene_permiso('products.create') THEN RAISE EXCEPTION 'No autorizado para crear servicios' USING ERRCODE='42501'; END IF;
  ELSE
    PERFORM private.assert_product_in_current_organization(p_service_id);
    IF NOT public.app_tiene_permiso('products.update') THEN RAISE EXCEPTION 'No autorizado para editar servicios' USING ERRCODE='42501'; END IF;
  END IF;
  IF NOT public.app_tiene_permiso('products.change_price') THEN RAISE EXCEPTION 'No autorizado para cambiar precios' USING ERRCODE='42501'; END IF;
  IF v_code='' OR length(v_code)>80 OR v_name='' OR length(v_name)>200 OR length(v_description)>2000
     OR p_unit_price IS NULL OR p_unit_price<0 OR p_purchase_price IS NULL OR p_purchase_price<0 THEN
    RAISE EXCEPTION 'Servicio inválido' USING ERRCODE='22023';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=v_organization_id
      AND upper(trim(coalesce(p.codigo,'')))=v_code
      AND (p_service_id IS NULL OR p.id<>p_service_id)
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto o servicio con ese código' USING ERRCODE='23505';
  END IF;

  IF p_service_id IS NULL THEN
    INSERT INTO public.productos(
      codigo,nombre,precio_unidad,precio_caja,precio_compra,unidad_medida,cantidad_por_caja,
      tipo_venta,permitir_sin_stock,stock_minimo,es_servicio,activo
    ) VALUES(v_code,v_name,p_unit_price,p_unit_price,p_purchase_price,'Servicios',1,'UNIDAD',true,0,true,true)
    RETURNING id INTO v_id;
  ELSE
    PERFORM 1 FROM public.productos
    WHERE organization_id=v_organization_id AND id=p_service_id AND es_servicio
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Servicio inexistente' USING ERRCODE='P0002'; END IF;
    UPDATE public.productos SET
      codigo=v_code,nombre=v_name,precio_unidad=p_unit_price,precio_caja=p_unit_price,
      precio_compra=p_purchase_price,unidad_medida='Servicios',cantidad_por_caja=1,tipo_venta='UNIDAD',
      permitir_sin_stock=true,stock_minimo=0,es_servicio=true,activo=true
    WHERE organization_id=v_organization_id AND id=p_service_id;
    v_id:=p_service_id;
  END IF;

  INSERT INTO public.service_metadata(product_id,description,updated_at)
  VALUES(v_id,v_description,now())
  ON CONFLICT(product_id) DO UPDATE SET description=EXCLUDED.description,updated_at=EXCLUDED.updated_at;

  INSERT INTO public.inventario_almacen(producto_id,almacen_id,cantidad)
  SELECT v_id,a.id,0 FROM public.almacenes a
  WHERE a.organization_id=v_organization_id AND coalesce(a.activo,true)
  ON CONFLICT(producto_id,almacen_id) DO UPDATE SET cantidad=0;

  RETURN public._service_json_v1(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.notificar_stock_bajo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_delta_total bigint;
  v_stock_minimo integer;
  v_stock_total_nuevo bigint;
  v_stock_total_viejo bigint;
  v_nombre_producto text;
  v_tipo_venta text;
  v_cantidad_por_caja integer;
  v_tipo_alerta text;
  v_texto_stock text;
  v_cajas bigint;
  v_sueltos bigint;
  v_onesignal_rest_api_key text;
  v_request_id bigint;
  v_cuerpo_json jsonb;
BEGIN
  DELETE FROM public.stock_alert_tx_context
  WHERE txid = txid_current()
    AND producto_id = NEW.producto_id
  RETURNING delta_total INTO v_delta_total;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT
    p.stock_minimo,
    p.nombre,
    COALESCE(p.tipo_venta, ''),
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
  INTO
    v_stock_minimo,
    v_nombre_producto,
    v_tipo_venta,
    v_cantidad_por_caja
  FROM public.productos AS p
  WHERE p.id = NEW.producto_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_stock_total_nuevo
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = NEW.producto_id;

  v_stock_total_viejo := v_stock_total_nuevo + COALESCE(v_delta_total, 0);

  IF v_stock_total_viejo > 0
     AND v_stock_total_nuevo <= 0 THEN
    v_tipo_alerta := 'agotado';
  ELSIF v_stock_minimo IS NOT NULL
     AND v_stock_total_viejo > v_stock_minimo
     AND v_stock_total_nuevo <= v_stock_minimo
     AND v_stock_total_nuevo > 0 THEN
    v_tipo_alerta := 'stock_bajo';
  ELSE
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'stock_bajo' THEN
    IF v_tipo_venta = 'CAJA_PAQUETES' THEN
      IF v_cantidad_por_caja <= 1 THEN
        v_texto_stock := v_stock_total_nuevo ||
          CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
      ELSE
        v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
        v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
        IF v_cajas = 0 THEN
          v_texto_stock := v_sueltos ||
            CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
        ELSIF v_sueltos = 0 THEN
          v_texto_stock := v_cajas ||
            CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
        ELSE
          v_texto_stock :=
            v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
            v_sueltos || CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
        END IF;
      END IF;
    ELSIF v_tipo_venta = 'CAJA_UNIDADES' THEN
      IF v_cantidad_por_caja <= 1 THEN
        v_texto_stock := v_stock_total_nuevo ||
          CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
      ELSE
        v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
        v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
        IF v_cajas = 0 THEN
          v_texto_stock := v_sueltos ||
            CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
        ELSIF v_sueltos = 0 THEN
          v_texto_stock := v_cajas ||
            CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
        ELSE
          v_texto_stock :=
            v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
            v_sueltos || CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
        END IF;
      END IF;
    ELSIF v_tipo_venta = 'PAQUETE' THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
    ELSIF v_tipo_venta = 'CAJA' THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' caja' ELSE ' cajas' END;
    ELSE
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
    END IF;
  END IF;

  BEGIN
    SELECT ds.decrypted_secret
    INTO v_onesignal_rest_api_key
    FROM vault.decrypted_secrets AS ds
    WHERE ds.name = 'onesignal_rest_api_key'
    ORDER BY ds.created_at DESC
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE WARNING 'OneSignal Vault no esta disponible; se omite alerta de stock.';
      RETURN NEW;
  END;

  IF NULLIF(TRIM(v_onesignal_rest_api_key), '') IS NULL THEN
    RAISE WARNING 'Falta el secreto onesignal_rest_api_key en Vault; se omite alerta de stock.';
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'agotado' THEN
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(128680) || ' ' || chr(161) || 'Producto Agotado!'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" se ha quedado sin stock (0). ' || chr(161) || 'Revisar inventario!'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'agotado',
        'producto_id', NEW.producto_id
      )
    );
  ELSE
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(9888) || chr(65039) || ' Alerta de Stock Bajo'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" est' || chr(225) || ' por agotarse. Quedan solo ' ||
        v_texto_stock || ' en total.'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'stock_bajo',
        'producto_id', NEW.producto_id
      )
    );
  END IF;

  BEGIN
    SELECT net.http_post(
      url := 'https://api.onesignal.com/notifications',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Key ' || v_onesignal_rest_api_key
      ),
      body := v_cuerpo_json
    )
    INTO v_request_id;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'No se pudo encolar la alerta de stock para producto %.', NEW.producto_id;
  END;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb)
  TO authenticated;
REVOKE ALL ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  TO authenticated;
REVOKE ALL ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric)
  TO authenticated;
REVOKE ALL ON FUNCTION public.notificar_stock_bajo()
  FROM PUBLIC, anon, authenticated;

COMMIT;
