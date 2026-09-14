-- Fase 3.4 SaaS: entrypoints activos de inventario con validación tenant-aware.
BEGIN;

CREATE OR REPLACE FUNCTION private.assert_warehouse_in_current_organization(p_warehouse_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_warehouse_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.almacenes
    WHERE organization_id = v_organization_id
      AND id = p_warehouse_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Warehouse not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_supplier_in_current_organization(p_supplier_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_supplier_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.proveedores
    WHERE organization_id = v_organization_id
      AND id = p_supplier_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Supplier not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_inventory_request_scope(p_request_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id is required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventario_operaciones_idempotentes
    WHERE request_id = p_request_id
      AND organization_id IS DISTINCT FROM v_organization_id
  ) OR EXISTS (
    SELECT 1 FROM public.inventory_traceability_receipts
    WHERE request_id = p_request_id
      AND organization_id IS DISTINCT FROM v_organization_id
  ) OR EXISTS (
    SELECT 1 FROM public.inventory_traceability_consumptions
    WHERE request_id = p_request_id
      AND organization_id IS DISTINCT FROM v_organization_id
  ) OR EXISTS (
    SELECT 1 FROM public.sys_processed_requests
    WHERE request_id = p_request_id
      AND organization_id IS DISTINCT FROM v_organization_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE='42501',
      MESSAGE='request_id is not available in current organization';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_warehouse_in_current_organization(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_supplier_in_current_organization(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_inventory_request_scope(uuid) FROM PUBLIC, anon, authenticated;

-- Lecturas trazables: SECURITY INVOKER + filtro explícito. RLS sigue siendo la
-- segunda barrera y evita depender de que el caller recuerde organization_id.
CREATE OR REPLACE FUNCTION public.list_inventory_lots_v1(
  p_product_id bigint DEFAULT NULL,
  p_warehouse_id bigint DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id',l.id,'product_id',l.product_id,'product_name',coalesce(p.nombre,''),
    'warehouse_id',l.warehouse_id,'warehouse_name',coalesce(a.nombre,''),
    'lot_code',l.lot_code,'expiry_date',l.expiry_date,'base_quantity',l.base_quantity
  )
  FROM public.inventory_lots l
  JOIN public.productos p
    ON p.organization_id=l.organization_id AND p.id=l.product_id
  JOIN public.almacenes a
    ON a.organization_id=l.organization_id AND a.id=l.warehouse_id
  WHERE l.organization_id = private.require_current_organization_id()
    AND private.has_permission('tenant.read')
    AND (p_product_id IS NULL OR l.product_id=p_product_id)
    AND (p_warehouse_id IS NULL OR l.warehouse_id=p_warehouse_id)
  ORDER BY l.expiry_date NULLS LAST,l.lot_code,l.id
$$;

CREATE OR REPLACE FUNCTION public.list_inventory_serials_v1(
  p_product_id bigint DEFAULT NULL,
  p_warehouse_id bigint DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id',s.id,'product_id',s.product_id,'product_name',coalesce(p.nombre,''),
    'warehouse_id',s.warehouse_id,'warehouse_name',coalesce(a.nombre,''),
    'serial_number',s.serial_number,'status',s.status
  )
  FROM public.inventory_serials s
  JOIN public.productos p
    ON p.organization_id=s.organization_id AND p.id=s.product_id
  JOIN public.almacenes a
    ON a.organization_id=s.organization_id AND a.id=s.warehouse_id
  WHERE s.organization_id = private.require_current_organization_id()
    AND private.has_permission('tenant.read')
    AND (p_product_id IS NULL OR s.product_id=p_product_id)
    AND (p_warehouse_id IS NULL OR s.warehouse_id=p_warehouse_id)
  ORDER BY s.serial_number,s.id
$$;

REVOKE ALL ON FUNCTION public.list_inventory_lots_v1(bigint,bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_inventory_serials_v1(bigint,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_inventory_lots_v1(bigint,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_inventory_serials_v1(bigint,bigint) TO authenticated;

-- Almacenes: no se consulta empleados.auth_id. La membership SaaS es autoridad.
CREATE OR REPLACE FUNCTION public.desactivar_almacen_seguro_v1(p_almacen_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_activo boolean;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Solo un administrador activo puede desactivar almacenes' USING ERRCODE='42501';
  END IF;

  SELECT activo INTO v_activo
  FROM public.almacenes
  WHERE organization_id=v_organization_id AND id=p_almacen_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Almacen no encontrado' USING ERRCODE='P0002'; END IF;
  IF coalesce(v_activo,false)=false THEN
    RETURN jsonb_build_object('success',true,'idempotent',true,'almacen_id',p_almacen_id,'activo',false);
  END IF;

  UPDATE public.almacenes
  SET activo=false,updated_at=now()
  WHERE organization_id=v_organization_id AND id=p_almacen_id;

  RETURN jsonb_build_object('success',true,'idempotent',false,'almacen_id',p_almacen_id,'activo',false);
END;
$$;

CREATE OR REPLACE FUNCTION public.reactivar_almacen_seguro_v1(p_almacen_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_activo boolean;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Solo un administrador activo puede reactivar almacenes' USING ERRCODE='42501';
  END IF;

  SELECT activo INTO v_activo
  FROM public.almacenes
  WHERE organization_id=v_organization_id AND id=p_almacen_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Almacen no encontrado' USING ERRCODE='P0002'; END IF;
  IF coalesce(v_activo,false)=true THEN
    RETURN jsonb_build_object('success',true,'idempotent',true,'almacen_id',p_almacen_id,'activo',true);
  END IF;

  UPDATE public.almacenes
  SET activo=true,updated_at=now()
  WHERE organization_id=v_organization_id AND id=p_almacen_id;

  RETURN jsonb_build_object('success',true,'idempotent',false,'almacen_id',p_almacen_id,'activo',true);
END;
$$;

REVOKE ALL ON FUNCTION public.desactivar_almacen_seguro_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reactivar_almacen_seguro_v1(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desactivar_almacen_seguro_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivar_almacen_seguro_v1(bigint) TO authenticated;

-- Operación base de ingreso: autorización SaaS, idempotencia y FK dentro del tenant.
CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_v2(
  p_request_id uuid,
  p_producto_id bigint,
  p_fecha timestamptz,
  p_tipo_ingreso text,
  p_documento text,
  p_proveedor_id bigint,
  p_observaciones text,
  p_almacenes jsonb,
  p_ingreso_costo numeric,
  p_ingreso_p_unit numeric,
  p_ingreso_p_caja numeric,
  p_ingreso_p_c_comp numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_item jsonb;
  v_almacen_id bigint;
  v_cantidad integer;
  v_almacenes bigint[] := '{}';
  v_proveedor text;
  v_motivo text;
  v_mov_id bigint;
  v_movimientos jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_contador integer := 0;
  v_resultado jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para registrar ingresos de inventario' USING ERRCODE='42501';
  END IF;

  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_supplier_in_current_organization(p_proveedor_id);

  IF p_almacenes IS NULL OR jsonb_typeof(p_almacenes)<>'array' OR jsonb_array_length(p_almacenes)=0 THEN
    RAISE EXCEPTION 'Debe enviar al menos un almacén' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || p_request_id::text,0));

  SELECT io.resultado,io.tipo_operacion,io.producto_id
  INTO v_previo,v_tipo_previo,v_producto_previo
  FROM public.inventario_operaciones_idempotentes io
  WHERE io.organization_id=v_organization_id AND io.request_id=p_request_id;

  IF FOUND THEN
    IF v_tipo_previo<>'INGRESO' OR v_producto_previo<>p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación' USING ERRCODE='23505';
    END IF;
    RETURN v_previo;
  END IF;

  IF p_proveedor_id IS NOT NULL THEN
    SELECT nombre INTO v_proveedor
    FROM public.proveedores
    WHERE organization_id=v_organization_id AND id=p_proveedor_id;
  END IF;

  v_motivo:=coalesce(nullif(trim(p_tipo_ingreso),''),'Ingreso de mercadería');
  IF nullif(trim(coalesce(p_documento,'')),'') IS NOT NULL THEN
    v_motivo:=v_motivo || ' | Doc: ' || trim(p_documento);
  END IF;
  IF nullif(trim(coalesce(p_observaciones,'')),'') IS NOT NULL THEN
    v_motivo:=v_motivo || ' | ' || trim(p_observaciones);
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_almacenes) LOOP
    v_almacen_id:=nullif(v_item->>'almacen_id','')::bigint;
    v_cantidad:=coalesce(nullif(v_item->>'cantidad_base','')::integer,0);
    PERFORM private.assert_warehouse_in_current_organization(v_almacen_id);

    IF v_cantidad<=0 THEN
      RAISE EXCEPTION 'La cantidad del almacén % debe ser mayor a cero',v_almacen_id USING ERRCODE='22023';
    END IF;
    IF v_almacen_id=ANY(v_almacenes) THEN
      RAISE EXCEPTION 'El almacén % está duplicado',v_almacen_id USING ERRCODE='22023';
    END IF;
    v_almacenes:=array_append(v_almacenes,v_almacen_id);

    v_mov_id:=public._aplicar_movimiento_inventario_v2(
      p_producto_id:=p_producto_id,p_almacen_id:=v_almacen_id,p_delta:=v_cantidad,
      p_tipo_movimiento:='ENTRADA',p_motivo:=v_motivo,p_fecha:=coalesce(p_fecha,now()),
      p_ingreso_costo:=coalesce(p_ingreso_costo,0),p_ingreso_p_unit:=coalesce(p_ingreso_p_unit,0),
      p_ingreso_p_caja:=p_ingreso_p_caja,p_ingreso_p_c_comp:=p_ingreso_p_c_comp,
      p_proveedor_nombre:=v_proveedor,p_request_id:=p_request_id
    );
    v_movimientos:=v_movimientos||jsonb_build_array(v_mov_id);
    v_total:=v_total+v_cantidad;
    v_contador:=v_contador+1;
  END LOOP;

  v_resultado:=jsonb_build_object(
    'success',true,'request_id',p_request_id,'producto_id',p_producto_id,
    'movimientos',v_movimientos,'almacenes_procesados',v_contador,'cantidad_base_total',v_total
  );

  INSERT INTO public.inventario_operaciones_idempotentes(request_id,tipo_operacion,producto_id,resultado)
  VALUES(p_request_id,'INGRESO',p_producto_id,v_resultado);
  RETURN v_resultado;
END;
$$;

-- Merma base tenant-aware. Los wrappers escalados existentes delegan aquí.
CREATE OR REPLACE FUNCTION public.registrar_merma_v2(
  p_request_id uuid,
  p_producto_id bigint,
  p_almacen_id bigint,
  p_cantidad integer,
  p_motivo text,
  p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_mov_id bigint;
  v_resultado jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para registrar mermas' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_warehouse_in_current_organization(p_almacen_id);

  IF p_cantidad IS NULL OR p_cantidad<=0 THEN
    RAISE EXCEPTION 'La cantidad debe ser mayor a cero' USING ERRCODE='22023';
  END IF;
  IF nullif(trim(coalesce(p_motivo,'')),'') IS NULL THEN
    RAISE EXCEPTION 'El motivo de la merma es obligatorio' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || p_request_id::text,0));
  SELECT resultado,tipo_operacion,producto_id
  INTO v_previo,v_tipo_previo,v_producto_previo
  FROM public.inventario_operaciones_idempotentes
  WHERE organization_id=v_organization_id AND request_id=p_request_id;

  IF FOUND THEN
    IF v_tipo_previo<>'MERMA' OR v_producto_previo<>p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación' USING ERRCODE='23505';
    END IF;
    RETURN v_previo;
  END IF;

  v_mov_id:=public._aplicar_movimiento_inventario_v2(
    p_producto_id:=p_producto_id,p_almacen_id:=p_almacen_id,p_delta:=-p_cantidad,
    p_tipo_movimiento:='MERMA',p_motivo:=trim(p_motivo),p_fecha:=coalesce(p_fecha,now()),
    p_request_id:=p_request_id
  );

  v_resultado:=jsonb_build_object(
    'success',true,'request_id',p_request_id,'producto_id',p_producto_id,
    'movimiento_id',v_mov_id,'cantidad_base',p_cantidad
  );
  INSERT INTO public.inventario_operaciones_idempotentes(request_id,tipo_operacion,producto_id,resultado)
  VALUES(p_request_id,'MERMA',p_producto_id,v_resultado);
  RETURN v_resultado;
END;
$$;

-- Traslado base tenant-aware. Impide origen/destino de organizaciones distintas.
CREATE OR REPLACE FUNCTION public.trasladar_stock_v2(
  p_request_id uuid,
  p_producto_id bigint,
  p_origen_id bigint,
  p_destino_id bigint,
  p_cantidad integer,
  p_motivo text DEFAULT NULL,
  p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_salida_id bigint;
  v_entrada_id bigint;
  v_transferencia_id bigint;
  v_resultado jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para trasladar stock' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_warehouse_in_current_organization(p_origen_id);
  PERFORM private.assert_warehouse_in_current_organization(p_destino_id);

  IF p_cantidad IS NULL OR p_cantidad<=0 OR p_origen_id=p_destino_id THEN
    RAISE EXCEPTION 'Traslado inválido' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || p_request_id::text,0));
  SELECT resultado,tipo_operacion,producto_id
  INTO v_previo,v_tipo_previo,v_producto_previo
  FROM public.inventario_operaciones_idempotentes
  WHERE organization_id=v_organization_id AND request_id=p_request_id;

  IF FOUND THEN
    IF v_tipo_previo<>'TRASLADO' OR v_producto_previo<>p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación' USING ERRCODE='23505';
    END IF;
    RETURN v_previo;
  END IF;

  v_salida_id:=public._aplicar_movimiento_inventario_v2(
    p_producto_id:=p_producto_id,p_almacen_id:=p_origen_id,p_delta:=-p_cantidad,
    p_tipo_movimiento:='TRASLADO_SALIDA',
    p_motivo:=coalesce(nullif(trim(p_motivo),''),'Traslado (origen)'),
    p_fecha:=coalesce(p_fecha,now()),p_request_id:=p_request_id
  );
  v_entrada_id:=public._aplicar_movimiento_inventario_v2(
    p_producto_id:=p_producto_id,p_almacen_id:=p_destino_id,p_delta:=p_cantidad,
    p_tipo_movimiento:='TRASLADO_ENTRADA',
    p_motivo:=coalesce(nullif(trim(p_motivo),''),'Traslado (destino)'),
    p_fecha:=coalesce(p_fecha,now()),p_request_id:=p_request_id
  );

  INSERT INTO public.transferencias_stock(
    request_id,producto_id,almacen_origen_id,almacen_destino_id,cantidad,fecha,motivo,
    movimiento_salida_id,movimiento_entrada_id
  ) VALUES(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad,coalesce(p_fecha,now()),
    nullif(trim(coalesce(p_motivo,'')),''),v_salida_id,v_entrada_id
  ) RETURNING id INTO v_transferencia_id;

  v_resultado:=jsonb_build_object(
    'success',true,'request_id',p_request_id,'producto_id',p_producto_id,
    'transferencia_id',v_transferencia_id,'movimiento_salida_id',v_salida_id,
    'movimiento_entrada_id',v_entrada_id,'cantidad_base',p_cantidad
  );
  INSERT INTO public.inventario_operaciones_idempotentes(request_id,tipo_operacion,producto_id,resultado)
  VALUES(p_request_id,'TRASLADO',p_producto_id,v_resultado);
  RETURN v_resultado;
END;
$$;

-- Entrypoints escalados usados por Flutter agregan assertions tempranas antes
-- de entrar a lógica histórica de escala/trazabilidad.
CREATE OR REPLACE FUNCTION public.ajustar_stock_scaled_v2(
  p_producto_id bigint,p_almacen_id bigint,p_delta_base numeric,p_tipo_movimiento text,p_motivo text,
  p_ingreso_costo numeric DEFAULT 0,p_ingreso_p_unit numeric DEFAULT 0,p_ingreso_p_caja numeric DEFAULT 0,
  p_ingreso_p_c_comp numeric DEFAULT 0,p_salida_cliente text DEFAULT NULL,p_salida_p_unit numeric DEFAULT 0,
  p_salida_total numeric DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para ajustar stock' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_warehouse_in_current_organization(p_almacen_id);
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'El ajuste genérico no está permitido para productos trazables' USING ERRCODE='23514';
  END IF;
  PERFORM public.ajustar_stock_scaled_v1(
    p_producto_id,p_almacen_id,p_delta_base,p_tipo_movimiento,p_motivo,
    p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp,
    p_salida_cliente,p_salida_p_unit,p_salida_total
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(
  p_request_id uuid,p_producto_id bigint,p_fecha timestamptz,p_tipo_ingreso text,p_documento text,
  p_proveedor_id bigint,p_observaciones text,p_almacenes jsonb,p_ingreso_costo numeric,
  p_ingreso_p_unit numeric,p_ingreso_p_caja numeric,p_ingreso_p_c_comp numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_item jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para registrar ingresos de inventario' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_supplier_in_current_organization(p_proveedor_id);
  IF p_almacenes IS NULL OR jsonb_typeof(p_almacenes)<>'array' THEN
    RAISE EXCEPTION 'Distribución de almacenes inválida' USING ERRCODE='22023';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_almacenes) LOOP
    PERFORM private.assert_warehouse_in_current_organization(nullif(v_item->>'almacen_id','')::bigint);
  END LOOP;
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'Este producto requiere una recepción con trazabilidad' USING ERRCODE='23514';
  END IF;
  RETURN public.registrar_ingreso_mercaderia_scaled_v1(
    p_request_id,p_producto_id,p_fecha,p_tipo_ingreso,p_documento,p_proveedor_id,
    p_observaciones,p_almacenes,p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v4(
  p_request_id uuid,p_producto_id bigint,p_almacen_id bigint,p_cantidad_base numeric,
  p_motivo text,p_fecha timestamptz DEFAULT now(),p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_serials jsonb:=p_serial_numbers; v_mode text;
BEGIN
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_warehouse_in_current_organization(p_almacen_id);
  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base) THEN
      RAISE EXCEPTION 'La merma seriada requiere cantidad entera' USING ERRCODE='23514';
    END IF;
    v_serials:=public._resolve_serial_numbers_v1(p_producto_id,p_almacen_id,p_cantidad_base::integer,p_serial_numbers);
  END IF;
  RETURN public.registrar_merma_scaled_v3(
    p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,p_motivo,p_fecha,v_serials
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v4(
  p_request_id uuid,p_producto_id bigint,p_origen_id bigint,p_destino_id bigint,p_cantidad_base numeric,
  p_motivo text DEFAULT NULL,p_fecha timestamptz DEFAULT now(),p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_serials jsonb:=p_serial_numbers; v_mode text;
BEGIN
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  PERFORM private.assert_warehouse_in_current_organization(p_origen_id);
  PERFORM private.assert_warehouse_in_current_organization(p_destino_id);
  IF p_origen_id=p_destino_id THEN RAISE EXCEPTION 'Traslado inválido' USING ERRCODE='22023'; END IF;
  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base) THEN
      RAISE EXCEPTION 'El traslado seriado requiere cantidad entera' USING ERRCODE='23514';
    END IF;
    v_serials:=public._resolve_serial_numbers_v1(p_producto_id,p_origen_id,p_cantidad_base::integer,p_serial_numbers);
  END IF;
  RETURN public.trasladar_stock_scaled_v3(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,p_motivo,p_fecha,v_serials
  );
END;
$$;

-- Recepción trazable: se conserva la implementación madura, pero el wrapper
-- evita que su SECURITY DEFINER vea request/product/warehouse de otro tenant.
ALTER FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) RENAME TO _legacy_register_traceable_merchandise_receipt_v1;
REVOKE ALL ON FUNCTION public._legacy_register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.register_traceable_merchandise_receipt_v1(
  p_request_id uuid,p_product_id bigint,p_warehouse_id bigint,p_total_base_quantity numeric,
  p_received_at timestamptz,p_entry_type text,p_document text,p_supplier_id bigint,p_observations text,
  p_unit_cost numeric,p_unit_price numeric,p_box_price numeric,p_comparative_box_price numeric,p_allocations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para recibir inventario' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_inventory_request_scope(p_request_id);
  PERFORM private.assert_product_in_current_organization(p_product_id);
  PERFORM private.assert_warehouse_in_current_organization(p_warehouse_id);
  PERFORM private.assert_supplier_in_current_organization(p_supplier_id);
  RETURN public._legacy_register_traceable_merchandise_receipt_v1(
    p_request_id,p_product_id,p_warehouse_id,p_total_base_quantity,p_received_at,
    p_entry_type,p_document,p_supplier_id,p_observations,p_unit_cost,p_unit_price,
    p_box_price,p_comparative_box_price,p_allocations
  );
END;
$$;

REVOKE ALL ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) TO authenticated;

-- Alta de producto + stock: elimina la dependencia empleados.auth_id y hace la
-- idempotencia/warehouse/supplier tenant-aware desde la primera escritura.
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
  v_tipo_venta:=upper(trim(coalesce(p_datos_producto->>'tipo_venta','')));
  v_proveedor_id:=nullif(p_datos_producto->>'proveedor_id','')::bigint;
  v_stock_minimo:=coalesce(nullif(p_datos_producto->>'stock_minimo','')::integer,0);

  IF v_codigo='' OR length(v_codigo)>50 OR v_codigo !~ '^[A-Z0-9._/-]+$' THEN
    RAISE EXCEPTION 'Código de producto inválido' USING ERRCODE='22023';
  END IF;
  IF v_nombre='' THEN RAISE EXCEPTION 'El nombre del producto no puede estar vacío' USING ERRCODE='22023'; END IF;
  IF v_tipo_venta NOT IN ('PAQUETES','CAJA_PAQUETES','CAJA_UNIDADES') THEN
    RAISE EXCEPTION 'tipo_venta inválido' USING ERRCODE='22023';
  END IF;
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

  v_unidad_medida:=CASE WHEN v_tipo_venta IN ('PAQUETES','CAJA_PAQUETES') THEN 'Paquetes' ELSE 'Unidades' END;
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

-- Servicios: código y almacenes quedan limitados al tenant actual.
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
    ) VALUES(v_code,v_name,p_unit_price,p_unit_price,p_purchase_price,'Servicios',1,'unidad',true,0,true,true)
    RETURNING id INTO v_id;
  ELSE
    PERFORM 1 FROM public.productos
    WHERE organization_id=v_organization_id AND id=p_service_id AND es_servicio
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Servicio inexistente' USING ERRCODE='P0002'; END IF;
    UPDATE public.productos SET
      codigo=v_code,nombre=v_name,precio_unidad=p_unit_price,precio_caja=p_unit_price,
      precio_compra=p_purchase_price,unidad_medida='Servicios',cantidad_por_caja=1,tipo_venta='unidad',
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

-- Guardas tempranas de catálogo que toca inventario/historial.
ALTER FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  RENAME TO _legacy_actualizar_producto_seguro_v1;
REVOKE ALL ON FUNCTION public._legacy_actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.actualizar_producto_seguro_v1(p_producto_id bigint,p_datos jsonb,p_actualizar_apertura boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  RETURN public._legacy_actualizar_producto_seguro_v1(p_producto_id,p_datos,p_actualizar_apertura);
END;
$$;

ALTER FUNCTION public.evaluar_eliminacion_producto_v1(bigint)
  RENAME TO _legacy_evaluar_eliminacion_producto_v1;
REVOKE ALL ON FUNCTION public._legacy_evaluar_eliminacion_producto_v1(bigint)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.evaluar_eliminacion_producto_v1(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  RETURN public._legacy_evaluar_eliminacion_producto_v1(p_producto_id);
END;
$$;

-- La función legacy de eliminación llama por nombre a evaluar_eliminacion_producto_v1;
-- tras crear el wrapper ese salto vuelve a pasar por la assertion del tenant.
ALTER FUNCTION public.eliminar_producto_seguro_v1(bigint)
  RENAME TO _legacy_eliminar_producto_seguro_v1;
REVOKE ALL ON FUNCTION public._legacy_eliminar_producto_seguro_v1(bigint)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.eliminar_producto_seguro_v1(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_producto_id);
  RETURN public._legacy_eliminar_producto_seguro_v1(p_producto_id);
END;
$$;

-- Exposición explícita sólo de entrypoints vigentes.
REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_merma_v2(uuid,bigint,bigint,integer,text,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trasladar_stock_v2(uuid,bigint,bigint,bigint,integer,text,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamptz,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.evaluar_eliminacion_producto_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.eliminar_producto_seguro_v1(bigint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.evaluar_eliminacion_producto_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_producto_seguro_v1(bigint) TO authenticated;

COMMIT;
