-- Cierre F3.3: la edición de producto deja de comparar unicidades globales.
BEGIN;

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
    'unidad_medida','cantidad_por_caja','proveedor_id','permitir_sin_stock',
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
  v_tipo_venta:=upper(trim(CASE WHEN p_datos?'tipo_venta' THEN coalesce(p_datos->>'tipo_venta','') ELSE coalesce(v_producto.tipo_venta,'') END));
  v_stock_minimo:=CASE WHEN p_datos?'stock_minimo' THEN coalesce(nullif(p_datos->>'stock_minimo','')::integer,0) ELSE coalesce(v_producto.stock_minimo,0) END;
  v_unidad_medida:=CASE
    WHEN v_tipo_venta IN ('PAQUETES','CAJA_PAQUETES') THEN 'Paquetes'
    WHEN v_tipo_venta='CAJA_UNIDADES' THEN 'Unidades'
    ELSE trim(CASE WHEN p_datos?'unidad_medida' THEN coalesce(p_datos->>'unidad_medida','') ELSE coalesce(v_producto.unidad_medida,'') END)
  END;

  IF v_codigo='' OR length(v_codigo)>50 OR v_codigo !~ '^[A-Z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Código de producto inválido' USING ERRCODE='22023';
  END IF;
  IF v_nombre='' THEN RAISE EXCEPTION 'El nombre del producto no puede estar vacío' USING ERRCODE='22023'; END IF;
  IF v_tipo_venta NOT IN ('PAQUETES','CAJA_PAQUETES','CAJA_UNIDADES') THEN RAISE EXCEPTION 'tipo_venta inválido' USING ERRCODE='22023'; END IF;
  IF v_precio_unidad<0 OR v_precio_caja<0 OR v_precio_compra<0 THEN RAISE EXCEPTION 'Los precios y costos no pueden ser negativos' USING ERRCODE='22023'; END IF;
  IF v_cantidad_por_caja<=1 THEN RAISE EXCEPTION 'La cantidad contenida en el empaque debe ser mayor a 1' USING ERRCODE='22023'; END IF;
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
      AND upper(trim(coalesce(p.tipo_venta,'')))=v_tipo_venta
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

    v_unidad_base:=CASE WHEN v_tipo_venta IN ('PAQUETES','CAJA_PAQUETES') THEN 'Paquete' ELSE 'Unidad' END;
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

REVOKE ALL ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean) TO authenticated;

COMMIT;
