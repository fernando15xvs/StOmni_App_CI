-- Fase 3.6 SaaS (RPC): compras, recepciones, gastos y deuda a proveedor tenant-aware.
-- Las operaciones que afectan Caja Chica permanecen fail-closed hasta F4.3.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Guards de negocio: eliminar el singleton business_id=1 y scopear productos.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._business_enforce_purchase_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_enabled boolean;
BEGIN
  SELECT b.purchase_management
  INTO v_enabled
  FROM public.business_capabilities AS b
  WHERE b.organization_id = v_org
  FOR SHARE;

  IF COALESCE(v_enabled,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'La gestión de compras está deshabilitada' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._service_block_purchase_line_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF EXISTS(
    SELECT 1
    FROM public.productos AS p
    WHERE p.organization_id=v_org
      AND p.id=NEW.product_id
      AND p.es_servicio
  ) THEN
    RAISE EXCEPTION 'Los servicios no se reciben como inventario' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._business_enforce_purchase_capability() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._service_block_purchase_line_v1() FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 2. Assertions privadas reutilizables.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.assert_supplier_in_current_organization(
  p_supplier_id bigint,
  p_require_active boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_supplier_id IS NULL THEN RETURN; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.proveedores AS p
    WHERE p.organization_id=v_org
      AND p.id=p_supplier_id
      AND (
        NOT COALESCE(p_require_active,false)
        OR (COALESCE(p.activo,true) AND lower(COALESCE(p.estado,'activo'))='activo')
      )
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Supplier not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_purchase_order_in_current_organization(p_order_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_order_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.purchase_orders
    WHERE organization_id=v_org AND id=p_order_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Purchase order not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_expense_in_current_organization(p_expense_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_expense_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.gastos
    WHERE organization_id=v_org AND id=p_expense_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Expense not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_expense_payment_in_current_organization(
  p_payment_id bigint,
  p_expense_id bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF p_payment_id IS NULL OR p_expense_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pagos_gasto
    WHERE organization_id=v_org AND id=p_payment_id AND gasto_id=p_expense_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Expense payment not available in current organization';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_purchase_payload_in_current_organization(
  p_request_id uuid,
  p_supplier_id bigint,
  p_warehouse_id bigint,
  p_lines jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_line jsonb;
  v_product_id bigint;
BEGIN
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id is required';
  END IF;

  PERFORM private.assert_supplier_in_current_organization(p_supplier_id,true);
  PERFORM private.assert_warehouse_in_current_organization(p_warehouse_id);

  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Purchase lines must be a non-empty array';
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    IF jsonb_typeof(v_line)<>'object' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid purchase line';
    END IF;
    v_product_id:=NULLIF(v_line->>'product_id','')::bigint;
    PERFORM private.assert_product_in_current_organization(v_product_id);
  END LOOP;

  -- Evita que un request_id ya existente en otro tenant se interprete como replay.
  IF EXISTS (
    SELECT 1 FROM public.purchase_orders
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23505', MESSAGE='Purchase request_id belongs to another organization';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_supplier_in_current_organization(bigint,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_purchase_order_in_current_organization(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_expense_in_current_organization(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_expense_payment_in_current_organization(bigint,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.assert_purchase_payload_in_current_organization(uuid,bigint,bigint,jsonb) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 3. Serializador privado de órdenes. Nunca consulta filas de otro tenant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.purchase_order_json(p_order_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id',o.id,
    'request_id',o.request_id::text,
    'supplier_id',o.supplier_id,
    'supplier_name',COALESCE(s.nombre,''),
    'warehouse_id',o.warehouse_id,
    'warehouse_name',COALESCE(a.nombre,''),
    'status',o.status,
    'ordered_at',o.ordered_at,
    'expected_at',o.expected_at,
    'notes',o.notes,
    'lines',COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',l.id,
        'product_id',l.product_id,
        'product_name',COALESCE(p.nombre,p.codigo,''),
        'ordered_base_quantity',l.ordered_base_quantity,
        'received_base_quantity',l.received_base_quantity,
        'unit_cost',l.unit_cost
      ) ORDER BY l.id)
      FROM public.purchase_order_lines AS l
      JOIN public.productos AS p
        ON p.organization_id=l.organization_id AND p.id=l.product_id
      WHERE l.organization_id=o.organization_id
        AND l.purchase_order_id=o.id
    ),'[]'::jsonb)
  )
  FROM public.purchase_orders AS o
  JOIN public.proveedores AS s
    ON s.organization_id=o.organization_id AND s.id=o.supplier_id
  JOIN public.almacenes AS a
    ON a.organization_id=o.organization_id AND a.id=o.warehouse_id
  WHERE o.organization_id=private.require_current_organization_id()
    AND o.id=p_order_id;
$$;

REVOKE ALL ON FUNCTION private.purchase_order_json(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._purchase_order_json(bigint) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 4. RPC activas de órdenes de compra.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_order_v1(
  p_request_id uuid,p_supplier_id bigint,p_warehouse_id bigint,
  p_ordered_at timestamptz,p_expected_at timestamptz,p_notes text,p_lines jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_order_id bigint;
  v_line jsonb;
  v_product_id bigint;
  v_quantity numeric;
  v_cost numeric;
  v_ordered_at timestamptz := COALESCE(p_ordered_at,now());
BEGIN
  IF NOT public.app_tiene_permiso('purchases.manage') THEN
    RAISE EXCEPTION 'No autorizado para crear compras' USING ERRCODE='42501';
  END IF;
  PERFORM private.assert_purchase_payload_in_current_organization(
    p_request_id,p_supplier_id,p_warehouse_id,p_lines
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || p_request_id::text,0));

  SELECT id INTO v_order_id
  FROM public.purchase_orders
  WHERE organization_id=v_org AND request_id=p_request_id;
  IF FOUND THEN RETURN private.purchase_order_json(v_order_id); END IF;

  IF p_expected_at IS NOT NULL AND p_expected_at<v_ordered_at THEN
    RAISE EXCEPTION 'Fecha esperada inválida' USING ERRCODE='22023';
  END IF;

  INSERT INTO public.purchase_orders(
    organization_id,request_id,supplier_id,warehouse_id,status,
    ordered_at,expected_at,notes,created_by
  ) VALUES (
    v_org,p_request_id,p_supplier_id,p_warehouse_id,'ordered',
    v_ordered_at,p_expected_at,COALESCE(trim(p_notes),''),auth.uid()
  ) RETURNING id INTO v_order_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_product_id:=NULLIF(v_line->>'product_id','')::bigint;
    v_quantity:=NULLIF(v_line->>'base_quantity','')::numeric;
    v_cost:=NULLIF(v_line->>'unit_cost','')::numeric;
    IF v_product_id IS NULL OR v_quantity IS NULL OR v_quantity<=0 OR v_cost IS NULL OR v_cost<0 THEN
      RAISE EXCEPTION 'Línea de compra inválida' USING ERRCODE='22023';
    END IF;
    PERFORM private.assert_product_in_current_organization(v_product_id);
    PERFORM public._visible_base_to_stored(v_product_id,v_quantity);

    INSERT INTO public.purchase_order_lines(
      organization_id,purchase_order_id,product_id,ordered_base_quantity,unit_cost
    ) VALUES (v_org,v_order_id,v_product_id,v_quantity,v_cost);
  END LOOP;

  RETURN private.purchase_order_json(v_order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_purchase_orders_v1(
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_id bigint;
BEGIN
  IF NOT public.app_tiene_permiso('purchases.manage') THEN
    RAISE EXCEPTION 'No autorizado para consultar compras' USING ERRCODE='42501';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('draft','ordered','partially_received','received','cancelled') THEN
    RAISE EXCEPTION 'Estado de orden inválido' USING ERRCODE='22023';
  END IF;

  FOR v_id IN
    SELECT o.id
    FROM public.purchase_orders AS o
    WHERE o.organization_id=v_org
      AND (p_status IS NULL OR o.status=p_status)
    ORDER BY o.ordered_at DESC,o.id DESC
    LIMIT greatest(1,least(COALESCE(p_limit,100),200))
  LOOP
    RETURN NEXT private.purchase_order_json(v_id);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_purchase_order_v1(
  p_purchase_order_id bigint,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_order public.purchase_orders%ROWTYPE;
BEGIN
  IF NOT public.app_tiene_permiso('purchases.manage') THEN
    RAISE EXCEPTION 'No autorizado para anular compras' USING ERRCODE='42501';
  END IF;
  IF NULLIF(trim(COALESCE(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Indica el motivo de anulación' USING ERRCODE='22023';
  END IF;
  PERFORM private.assert_purchase_order_in_current_organization(p_purchase_order_id);

  SELECT * INTO v_order
  FROM public.purchase_orders
  WHERE organization_id=v_org AND id=p_purchase_order_id
  FOR UPDATE;

  IF v_order.status='received' OR EXISTS (
    SELECT 1 FROM public.purchase_order_lines
    WHERE organization_id=v_org
      AND purchase_order_id=p_purchase_order_id
      AND received_base_quantity>0
  ) THEN
    RAISE EXCEPTION 'Una orden con mercadería recibida no puede anularse' USING ERRCODE='23514';
  END IF;
  IF v_order.status='cancelled' THEN RETURN private.purchase_order_json(p_purchase_order_id); END IF;

  UPDATE public.purchase_orders
  SET status='cancelled',cancelled_reason=trim(p_reason),updated_at=now()
  WHERE organization_id=v_org AND id=p_purchase_order_id;

  RETURN private.purchase_order_json(p_purchase_order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.receive_purchase_order_v2(
  p_request_id uuid,p_purchase_order_id bigint,p_received_at timestamptz,
  p_document text,p_notes text,p_lines jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
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
  PERFORM private.assert_purchase_order_in_current_organization(p_purchase_order_id);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || p_request_id::text,0));

  IF EXISTS (
    SELECT 1 FROM public.purchase_receipts
    WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org
  ) THEN
    RAISE EXCEPTION 'El request_id pertenece a otra organización' USING ERRCODE='23505';
  END IF;

  SELECT r.purchase_order_id INTO v_existing_order_id
  FROM public.purchase_receipts AS r
  WHERE r.organization_id=v_org AND r.request_id=p_request_id;
  IF FOUND THEN
    IF v_existing_order_id<>p_purchase_order_id THEN
      RAISE EXCEPTION 'El request_id pertenece a otra orden' USING ERRCODE='23505';
    END IF;
    RETURN private.purchase_order_json(v_existing_order_id);
  END IF;

  SELECT * INTO v_order
  FROM public.purchase_orders
  WHERE organization_id=v_org AND id=p_purchase_order_id
  FOR UPDATE;
  IF v_order.status NOT IN ('ordered','partially_received') THEN
    RAISE EXCEPTION 'La orden no admite recepciones en su estado actual' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.purchase_receipts(
    organization_id,request_id,purchase_order_id,received_at,document,notes,received_by
  ) VALUES (
    v_org,p_request_id,p_purchase_order_id,COALESCE(p_received_at,now()),
    COALESCE(trim(p_document),''),COALESCE(trim(p_notes),''),auth.uid()
  ) RETURNING id INTO v_receipt_id;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    SELECT * INTO v_order_line
    FROM public.purchase_order_lines
    WHERE organization_id=v_org
      AND id=NULLIF(v_line->>'purchase_order_line_id','')::bigint
      AND purchase_order_id=p_purchase_order_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Línea de compra inexistente' USING ERRCODE='P0002'; END IF;

    v_quantity:=NULLIF(v_line->>'base_quantity','')::numeric;
    v_pending:=v_order_line.ordered_base_quantity-v_order_line.received_base_quantity;
    IF v_quantity IS NULL OR v_quantity<=0 OR v_quantity>v_pending THEN
      RAISE EXCEPTION 'Cantidad recibida excede lo pendiente' USING ERRCODE='23514';
    END IF;
    PERFORM private.assert_product_in_current_organization(v_order_line.product_id);
    PERFORM public._visible_base_to_stored(v_order_line.product_id,v_quantity);

    INSERT INTO public.purchase_receipt_lines(
      organization_id,purchase_receipt_id,purchase_order_line_id,base_quantity
    ) VALUES (v_org,v_receipt_id,v_order_line.id,v_quantity);

    SELECT * INTO v_product
    FROM public.productos
    WHERE organization_id=v_org AND id=v_order_line.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no disponible' USING ERRCODE='P0002'; END IF;

    v_active_mode:=public._active_traceability_mode_v1(v_order_line.product_id);
    v_allocations:=COALESCE(v_line->'allocations','[]'::jsonb);
    v_line_request:=(md5(p_request_id::text || ':' || v_order_line.id::text))::uuid;

    IF v_active_mode IN ('lot','serial') THEN
      IF jsonb_typeof(v_allocations)<>'array' OR jsonb_array_length(v_allocations)=0 THEN
        RAISE EXCEPTION 'La línea % requiere asignación de trazabilidad',v_order_line.id USING ERRCODE='23514';
      END IF;
      PERFORM public.register_traceable_merchandise_receipt_v1(
        v_line_request,v_order_line.product_id,v_order.warehouse_id,v_quantity,
        COALESCE(p_received_at,now()),'Compra',COALESCE(trim(p_document),''),
        v_order.supplier_id,
        'Recepción OC #' || p_purchase_order_id::text ||
          CASE WHEN NULLIF(trim(COALESCE(p_notes,'')),'') IS NULL THEN '' ELSE ' · ' || trim(p_notes) END,
        v_order_line.unit_cost,COALESCE(v_product.precio_unidad,0),
        COALESCE(v_product.precio_caja,0),
        COALESCE(v_product.precio_caja,0)*greatest(COALESCE(v_product.cantidad_por_caja,1),1),
        v_allocations
      );
    ELSE
      IF jsonb_typeof(v_allocations)<>'array' OR jsonb_array_length(v_allocations)>0 THEN
        RAISE EXCEPTION 'La línea % no tiene trazabilidad activa',v_order_line.id USING ERRCODE='22023';
      END IF;
      PERFORM public.registrar_ingreso_mercaderia_scaled_v2(
        v_line_request,v_order_line.product_id,COALESCE(p_received_at,now()),
        'Compra',COALESCE(trim(p_document),''),v_order.supplier_id,
        'Recepción OC #' || p_purchase_order_id::text ||
          CASE WHEN NULLIF(trim(COALESCE(p_notes,'')),'') IS NULL THEN '' ELSE ' · ' || trim(p_notes) END,
        jsonb_build_array(jsonb_build_object('almacen_id',v_order.warehouse_id,'cantidad_base',v_quantity)),
        v_order_line.unit_cost,COALESCE(v_product.precio_unidad,0),
        COALESCE(v_product.precio_caja,0),
        COALESCE(v_product.precio_caja,0)*greatest(COALESCE(v_product.cantidad_por_caja,1),1)
      );
    END IF;

    UPDATE public.purchase_order_lines
    SET received_base_quantity=received_base_quantity+v_quantity
    WHERE organization_id=v_org AND id=v_order_line.id;
  END LOOP;

  UPDATE public.purchase_orders AS o
  SET status=CASE WHEN NOT EXISTS(
        SELECT 1 FROM public.purchase_order_lines AS l
        WHERE l.organization_id=v_org
          AND l.purchase_order_id=o.id
          AND l.received_base_quantity<l.ordered_base_quantity
      ) THEN 'received' ELSE 'partially_received' END,
      updated_at=now()
  WHERE o.organization_id=v_org AND o.id=p_purchase_order_id;

  RETURN private.purchase_order_json(p_purchase_order_id);
END;
$$;

-- v1 queda sólo como implementación histórica no invocable por clientes.
REVOKE ALL ON FUNCTION public.receive_purchase_order_v1(uuid,bigint,timestamptz,text,text,jsonb) FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 5. Gastos/cuentas por pagar: lectura directa por RLS, mutaciones sólo por RPC.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_gasto_mixto(
  p_proveedor_id bigint,p_categoria text,p_monto_total numeric,p_descripcion text,
  p_fecha timestamptz,p_pagos_json jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_saldo_restante numeric;
  v_estado text;
  v_gasto_id bigint;
  v_total_pagado numeric := 0;
  v_pago jsonb;
  v_monto numeric;
  v_metodo text;
  v_afecta_caja boolean;
  v_fecha timestamptz := COALESCE(p_fecha,now());
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  IF p_proveedor_id IS NOT NULL THEN
    PERFORM private.assert_supplier_in_current_organization(p_proveedor_id,true);
  END IF;
  IF p_monto_total IS NULL OR p_monto_total<=0 THEN
    RAISE EXCEPTION 'El monto total del gasto debe ser mayor a cero.' USING ERRCODE='22023';
  END IF;
  IF p_pagos_json IS NOT NULL AND jsonb_typeof(p_pagos_json)<>'array' THEN
    RAISE EXCEPTION 'Los pagos deben enviarse como un arreglo JSON.' USING ERRCODE='22023';
  END IF;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      IF jsonb_typeof(v_pago)<>'object' THEN
        RAISE EXCEPTION 'Cada pago debe ser un objeto JSON.' USING ERRCODE='22023';
      END IF;
      v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
      v_metodo:=trim(COALESCE(v_pago->>'metodo',''));
      v_afecta_caja:=COALESCE((v_pago->>'afecta_caja_chica')::boolean,false);
      IF v_monto<=0 OR v_metodo='' THEN
        RAISE EXCEPTION 'Todos los pagos deben indicar método y monto positivo.' USING ERRCODE='22023';
      END IF;
      IF v_afecta_caja THEN
        RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Cash-box expense payments are disabled until cash sessions are tenant-aware in F4.3';
      END IF;
      v_total_pagado:=v_total_pagado+v_monto;
    END LOOP;
  END IF;

  IF v_total_pagado>p_monto_total+0.02 THEN
    RAISE EXCEPTION 'Los pagos superan el monto total del gasto.' USING ERRCODE='23514';
  END IF;

  v_saldo_restante:=GREATEST(p_monto_total-v_total_pagado,0);
  v_estado:=CASE WHEN v_saldo_restante<=0.02 THEN 'pagado' ELSE 'pendiente' END;

  INSERT INTO public.gastos(
    organization_id,fecha,proveedor_id,categoria,monto,descripcion,estado,saldo
  ) VALUES (
    v_org,v_fecha,p_proveedor_id,p_categoria,p_monto_total,p_descripcion,v_estado,v_saldo_restante
  ) RETURNING id INTO v_gasto_id;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
      v_metodo:=trim(COALESCE(v_pago->>'metodo',''));
      INSERT INTO public.pagos_gasto(
        organization_id,gasto_id,metodo,monto,fecha,afecta_caja_chica
      ) VALUES (v_org,v_gasto_id,v_metodo,v_monto,v_fecha,false);
    END LOOP;
  END IF;

  RETURN v_gasto_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_gasto_v1(p_gasto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  PERFORM private.assert_expense_in_current_organization(p_gasto_id);
  DELETE FROM public.gastos WHERE organization_id=v_org AND id=p_gasto_id;
  RETURN jsonb_build_object('success',true,'gasto_id',p_gasto_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_pago_gasto_v1(p_pago_id bigint,p_gasto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_gasto public.gastos%ROWTYPE;
  v_total_pagado numeric := 0;
  v_nuevo_saldo numeric := 0;
  v_estado text;
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  PERFORM private.assert_expense_payment_in_current_organization(p_pago_id,p_gasto_id);

  SELECT * INTO v_gasto
  FROM public.gastos
  WHERE organization_id=v_org AND id=p_gasto_id
  FOR UPDATE;

  DELETE FROM public.pagos_gasto
  WHERE organization_id=v_org AND id=p_pago_id AND gasto_id=p_gasto_id;

  SELECT COALESCE(SUM(monto),0) INTO v_total_pagado
  FROM public.pagos_gasto
  WHERE organization_id=v_org AND gasto_id=p_gasto_id;

  v_nuevo_saldo:=GREATEST(v_gasto.monto-v_total_pagado,0);
  v_estado:=CASE WHEN v_nuevo_saldo<=0.02 THEN 'pagado' ELSE 'pendiente' END;

  UPDATE public.gastos
  SET saldo=v_nuevo_saldo,estado=v_estado
  WHERE organization_id=v_org AND id=p_gasto_id;

  RETURN jsonb_build_object(
    'success',true,'gasto_id',p_gasto_id,'pago_id',p_pago_id,
    'saldo',v_nuevo_saldo,'estado',v_estado
  );
END;
$$;

-- La firma legacy de un solo pago no es usada por Flutter; se retira de la API.
REVOKE ALL ON FUNCTION public.registrar_gasto(bigint,text,numeric,numeric,text,text,timestamptz,boolean)
  FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 6. Reactivar pagos a proveedor no-cash en procesar_pago_deuda_v2.
--    El motor legacy sigue interno; se scopea también su rama de gastos.
-- -----------------------------------------------------------------------------
DO $patch_supplier_debt_legacy$
DECLARE
  v_sig regprocedure := 'public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'FROM public.gastos AS g\n    WHERE g.id = p_deuda_id\n    FOR UPDATE;';
  v_new:=E'FROM public.gastos AS g\n    WHERE g.organization_id = private.require_current_organization_id()\n      AND g.id = p_deuda_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.6 debt patch mismatch: supplier expense lookup'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.gastos\n    SET saldo = v_nuevo_saldo,\n        estado = CASE WHEN v_nuevo_saldo <= 0.01 THEN ''pagado'' ELSE ''pendiente'' END\n    WHERE id = p_deuda_id;';
  v_new:=E'UPDATE public.gastos\n    SET saldo = v_nuevo_saldo,\n        estado = CASE WHEN v_nuevo_saldo <= 0.01 THEN ''pagado'' ELSE ''pendiente'' END\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = p_deuda_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.6 debt patch mismatch: supplier expense update'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'UPDATE public.pagos_deuda_requests\n  SET resultado = v_resultado, completed_at = now()\n  WHERE request_id = p_request_id;';
  v_new:=E'UPDATE public.pagos_deuda_requests\n  SET resultado = v_resultado, completed_at = now()\n  WHERE organization_id = private.require_current_organization_id()\n    AND request_id = p_request_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  EXECUTE v_def;
END;
$patch_supplier_debt_legacy$;

CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2(
  p_request_id uuid,p_es_cliente boolean,p_deuda_id bigint,p_monto numeric,
  p_metodo text,p_fecha timestamptz,p_descontar_de_caja boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.require_current_organization_id();
  PERFORM private.assert_sales_request_scope(p_request_id);

  IF p_es_cliente IS TRUE THEN
    IF NOT public.app_tiene_permiso('sales.create') THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
    END IF;
    IF lower(btrim(COALESCE(p_metodo,'')))='efectivo' THEN
      RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Cash debt payments are disabled until cash sessions are tenant-aware in F4.3';
    END IF;
    PERFORM private.assert_sale_in_current_organization(p_deuda_id);
    RETURN public._legacy_procesar_pago_deuda_v2(
      p_request_id,true,p_deuda_id,p_monto,p_metodo,p_fecha,false
    );
  END IF;

  IF p_es_cliente IS FALSE THEN
    IF NOT public.app_tiene_permiso('purchases.manage') THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Purchases permission required';
    END IF;
    IF COALESCE(p_descontar_de_caja,false) THEN
      RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Cash-box supplier payments are disabled until cash sessions are tenant-aware in F4.3';
    END IF;
    PERFORM private.assert_expense_in_current_organization(p_deuda_id);
    RETURN public._legacy_procesar_pago_deuda_v2(
      p_request_id,false,p_deuda_id,p_monto,p_metodo,p_fecha,false
    );
  END IF;

  RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Debt type is required';
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. Allowlist explícita de RPC cliente.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_purchase_order_v1(uuid,bigint,bigint,timestamptz,timestamptz,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.list_purchase_orders_v1(text,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.cancel_purchase_order_v1(bigint,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.eliminar_gasto_v1(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.eliminar_pago_gasto_v1(bigint,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.create_purchase_order_v1(uuid,bigint,bigint,timestamptz,timestamptz,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_purchase_orders_v1(text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_order_v1(bigint,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_gasto_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_pago_gasto_v1(bigint,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) TO authenticated;

COMMIT;
