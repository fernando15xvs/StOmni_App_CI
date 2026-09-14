-- Fase 5.2 SaaS: catálogo genérico (inventariable, no inventariable, servicio y bundle).
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Tipo explícito de ítem. `es_servicio` se conserva como compatibilidad legacy.
-- -----------------------------------------------------------------------------
ALTER TABLE public.productos
  ADD COLUMN item_type text NOT NULL DEFAULT 'stock_product';

UPDATE public.productos
SET item_type=CASE WHEN COALESCE(es_servicio,false) THEN 'service' ELSE 'stock_product' END;

ALTER TABLE public.productos
  ADD CONSTRAINT productos_item_type_valid
  CHECK (item_type IN ('stock_product','non_stock_product','service','bundle'));

COMMENT ON COLUMN public.productos.item_type IS
  'Tipo genérico de catálogo. stock_product usa inventario; non_stock_product/service/bundle no tienen stock propio.';

CREATE OR REPLACE FUNCTION private.normalize_catalog_item_type()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Compatibilidad: save_service_v1 histórico sólo envía es_servicio=true.
  IF COALESCE(NEW.es_servicio,false)
     AND (TG_OP='INSERT' OR OLD.es_servicio IS DISTINCT FROM NEW.es_servicio)
     AND NEW.item_type='stock_product' THEN
    NEW.item_type:='service';
  END IF;

  IF NEW.item_type='service' THEN
    NEW.es_servicio:=true;
  ELSE
    NEW.es_servicio:=false;
  END IF;

  IF NEW.item_type IN ('non_stock_product','service','bundle') THEN
    NEW.permitir_sin_stock:=true;
    NEW.stock_minimo:=0;
  END IF;

  IF NEW.item_type='bundle' THEN
    NEW.unidad_medida:='Unidad';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='unidad';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.normalize_catalog_item_type() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS zz_productos_catalog_item_type ON public.productos;
CREATE TRIGGER zz_productos_catalog_item_type
BEFORE INSERT OR UPDATE ON public.productos
FOR EACH ROW EXECUTE FUNCTION private.normalize_catalog_item_type();

-- -----------------------------------------------------------------------------
-- 2. Componentes de bundle. Un bundle no puede contener otro bundle en V1.
-- -----------------------------------------------------------------------------
CREATE TABLE public.bundle_components (
  organization_id uuid NOT NULL,
  bundle_product_id bigint NOT NULL,
  component_product_id bigint NOT NULL,
  quantity numeric(18,6) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bundle_components_pkey PRIMARY KEY(organization_id,bundle_product_id,component_product_id),
  CONSTRAINT bundle_components_organization_fkey
    FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT bundle_components_bundle_fkey
    FOREIGN KEY(organization_id,bundle_product_id)
    REFERENCES public.productos(organization_id,id) ON DELETE CASCADE,
  CONSTRAINT bundle_components_component_fkey
    FOREIGN KEY(organization_id,component_product_id)
    REFERENCES public.productos(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT bundle_components_distinct_products CHECK(bundle_product_id<>component_product_id),
  CONSTRAINT bundle_components_quantity_positive CHECK(quantity>0 AND quantity<=1000000000)
);
CREATE INDEX bundle_components_component_idx
  ON public.bundle_components(organization_id,component_product_id);

ALTER TABLE public.bundle_components ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.bundle_components FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.bundle_components TO authenticated;
CREATE POLICY bundle_components_tenant_select ON public.bundle_components
FOR SELECT TO authenticated
USING(private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

CREATE OR REPLACE FUNCTION private.validate_bundle_component()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_bundle_type text;
  v_component_type text;
BEGIN
  NEW.organization_id:=v_org;
  SELECT item_type INTO v_bundle_type
  FROM public.productos
  WHERE organization_id=v_org AND id=NEW.bundle_product_id AND COALESCE(activo,true)
  FOR SHARE;
  IF v_bundle_type IS DISTINCT FROM 'bundle' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundle component parent must be an active bundle';
  END IF;

  SELECT item_type INTO v_component_type
  FROM public.productos
  WHERE organization_id=v_org AND id=NEW.component_product_id AND COALESCE(activo,true)
  FOR SHARE;
  IF v_component_type IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Bundle component is not available in current organization';
  END IF;
  IF v_component_type='bundle' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Nested bundles are not supported';
  END IF;
  NEW.updated_at:=clock_timestamp();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.validate_bundle_component() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER bundle_components_validate
BEFORE INSERT OR UPDATE ON public.bundle_components
FOR EACH ROW EXECUTE FUNCTION private.validate_bundle_component();

CREATE OR REPLACE FUNCTION public.get_bundle_components_v1(p_bundle_product_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant read permission required';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=v_org AND p.id=p_bundle_product_id AND p.item_type='bundle'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Bundle not available in current organization';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'product_id',bc.component_product_id,
    'quantity',bc.quantity,
    'name',p.nombre,
    'item_type',p.item_type
  ) ORDER BY p.nombre,p.id),'[]'::jsonb)
  INTO v_result
  FROM public.bundle_components bc
  JOIN public.productos p
    ON p.organization_id=bc.organization_id AND p.id=bc.component_product_id
  WHERE bc.organization_id=v_org AND bc.bundle_product_id=p_bundle_product_id;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_bundle_components_v1(
  p_bundle_product_id bigint,
  p_components jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row jsonb;
  v_component_id bigint;
  v_quantity numeric;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant administrator permission required';
  END IF;
  IF p_components IS NULL OR jsonb_typeof(p_components)<>'array' OR jsonb_array_length(p_components)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Bundle requires at least one component';
  END IF;
  PERFORM 1 FROM public.productos p
  WHERE p.organization_id=v_org AND p.id=p_bundle_product_id AND p.item_type='bundle' AND COALESCE(p.activo,true)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Bundle not available in current organization'; END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp._stomni_bundle_components(
    component_product_id bigint PRIMARY KEY,
    quantity numeric(18,6) NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE pg_temp._stomni_bundle_components;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_components)
  LOOP
    IF jsonb_typeof(v_row)<>'object' THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid bundle component'; END IF;
    v_component_id:=NULLIF(v_row->>'product_id','')::bigint;
    v_quantity:=NULLIF(v_row->>'quantity','')::numeric;
    IF v_component_id IS NULL OR v_quantity IS NULL OR v_quantity<=0 OR v_quantity>1000000000 THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid bundle component quantity';
    END IF;
    INSERT INTO pg_temp._stomni_bundle_components(component_product_id,quantity)
    VALUES(v_component_id,v_quantity)
    ON CONFLICT(component_product_id) DO UPDATE SET quantity=EXCLUDED.quantity;
  END LOOP;

  DELETE FROM public.bundle_components
  WHERE organization_id=v_org AND bundle_product_id=p_bundle_product_id;

  INSERT INTO public.bundle_components(organization_id,bundle_product_id,component_product_id,quantity)
  SELECT v_org,p_bundle_product_id,t.component_product_id,t.quantity
  FROM pg_temp._stomni_bundle_components t;

  RETURN public.get_bundle_components_v1(p_bundle_product_id);
END;
$$;

REVOKE ALL ON FUNCTION public.get_bundle_components_v1(bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_bundle_components_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_bundle_components_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_bundle_components_v1(bigint,jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. No-stock semantics centralizadas. Sustituye guards específicos de servicio.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._item_type_zero_inventory_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_type text;
BEGIN
  SELECT p.item_type INTO v_type
  FROM public.productos p
  WHERE p.organization_id=NEW.organization_id AND p.id=NEW.producto_id;
  IF v_type IN ('non_stock_product','service','bundle') THEN NEW.cantidad:=0; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._item_type_zero_inventory_v1() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_inventory_always_zero ON public.inventario_almacen;
DROP TRIGGER IF EXISTS item_type_inventory_always_zero ON public.inventario_almacen;
CREATE TRIGGER item_type_inventory_always_zero
BEFORE INSERT OR UPDATE OF cantidad ON public.inventario_almacen
FOR EACH ROW EXECUTE FUNCTION public._item_type_zero_inventory_v1();

CREATE OR REPLACE FUNCTION public._item_type_skip_kardex_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=NEW.organization_id AND p.id=NEW.producto_id
      AND p.item_type IN ('non_stock_product','service','bundle')
  ) THEN RETURN NULL; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._item_type_skip_kardex_v1() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_no_inventory_movements ON public.inventario_movimientos;
DROP TRIGGER IF EXISTS item_type_no_inventory_movements ON public.inventario_movimientos;
CREATE TRIGGER item_type_no_inventory_movements
BEFORE INSERT ON public.inventario_movimientos
FOR EACH ROW EXECUTE FUNCTION public._item_type_skip_kardex_v1();

CREATE OR REPLACE FUNCTION public._item_type_block_purchase_line_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=NEW.organization_id AND p.id=NEW.product_id
      AND p.item_type<>'stock_product'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Only stock products can be received as inventory';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._item_type_block_purchase_line_v1() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_not_purchase_inventory ON public.purchase_order_lines;
DROP TRIGGER IF EXISTS item_type_not_purchase_inventory ON public.purchase_order_lines;
CREATE TRIGGER item_type_not_purchase_inventory
BEFORE INSERT OR UPDATE OF product_id ON public.purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION public._item_type_block_purchase_line_v1();

CREATE OR REPLACE FUNCTION public._item_type_block_traceability_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.mode<>'none' AND EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.organization_id=NEW.organization_id AND p.id=NEW.product_id
      AND p.item_type<>'stock_product'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Only stock products can use lot/serial traceability';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._item_type_block_traceability_v1() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_not_traceable ON public.product_traceability_configs;
DROP TRIGGER IF EXISTS item_type_not_traceable ON public.product_traceability_configs;
CREATE TRIGGER item_type_not_traceable
BEFORE INSERT OR UPDATE OF mode ON public.product_traceability_configs
FOR EACH ROW EXECUTE FUNCTION public._item_type_block_traceability_v1();

-- F5.1 inventory capability: los ítems no inventariables pueden mantener filas cero
-- aun con inventario desactivado; sólo stock_product queda bloqueado.
CREATE OR REPLACE FUNCTION private.enforce_inventory_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=COALESCE(private.current_organization_id(),CASE WHEN TG_OP='DELETE' THEN OLD.organization_id ELSE NEW.organization_id END);
  v_product_id bigint:=CASE WHEN TG_OP='DELETE' THEN OLD.producto_id ELSE NEW.producto_id END;
  v_type text;
BEGIN
  SELECT p.item_type INTO v_type FROM public.productos p
  WHERE p.organization_id=v_org AND p.id=v_product_id;
  IF v_type IS DISTINCT FROM 'stock_product' THEN
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF NOT COALESCE((SELECT b.inventory_enabled FROM public.business_capabilities b WHERE b.organization_id=v_org),false) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory capability is disabled';
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_inventory_capability() FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- 4. Bundle sale expansion + immutable sale snapshot.
-- -----------------------------------------------------------------------------
ALTER TABLE public.detalle_ventas
  ADD COLUMN bundle_components_snapshot jsonb;

CREATE OR REPLACE FUNCTION private.consume_bundle_components_on_sale_detail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_type text;
  v_component record;
  v_scale integer;
  v_stored numeric;
  v_stock integer;
  v_saldo integer;
  v_snapshot jsonb:='[]'::jsonb;
  v_request_id uuid;
  v_customer text;
  v_seller_id bigint;
  v_seller_name text;
  v_date timestamptz;
BEGIN
  SELECT p.item_type INTO v_type
  FROM public.productos p
  WHERE p.organization_id=NEW.organization_id AND p.id=NEW.producto_id;
  IF v_type IS DISTINCT FROM 'bundle' THEN RETURN NEW; END IF;
  IF lower(btrim(COALESCE(NEW.tipo_unidad,'unidad')))<>'unidad' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundles are sold by unit in catalog V1';
  END IF;

  SELECT v.request_id,COALESCE(c.nombre,'CLIENTE GENERAL'),v.vendedor_id,e.nombre,v.fecha
  INTO v_request_id,v_customer,v_seller_id,v_seller_name,v_date
  FROM public.ventas v
  LEFT JOIN public.clientes c ON c.organization_id=v.organization_id AND c.id=v.cliente_id
  LEFT JOIN public.empleados e ON e.organization_id=v.organization_id AND e.id=v.vendedor_id
  WHERE v.organization_id=NEW.organization_id AND v.id=NEW.venta_id;

  IF NOT EXISTS(
    SELECT 1 FROM public.bundle_components bc
    WHERE bc.organization_id=NEW.organization_id AND bc.bundle_product_id=NEW.producto_id
  ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundle has no configured components'; END IF;

  FOR v_component IN
    SELECT bc.component_product_id,bc.quantity,p.nombre,p.item_type,p.permitir_sin_stock,
           COALESCE(pr.nombre,'Generico') proveedor,
           COALESCE(up.profile,'{}'::jsonb) profile
    FROM public.bundle_components bc
    JOIN public.productos p ON p.organization_id=bc.organization_id AND p.id=bc.component_product_id
    LEFT JOIN public.proveedores pr ON pr.organization_id=p.organization_id AND pr.id=p.proveedor_id
    LEFT JOIN public.product_unit_profiles up ON up.organization_id=p.organization_id AND up.product_id=p.id
    WHERE bc.organization_id=NEW.organization_id AND bc.bundle_product_id=NEW.producto_id
    ORDER BY bc.component_product_id
  LOOP
    v_scale:=CASE WHEN v_component.profile='{}'::jsonb THEN 1 ELSE public._product_unit_storage_scale(v_component.profile) END;
    v_stored:=v_component.quantity * NEW.cantidad * v_scale;
    IF v_stored<=0 OR v_stored<>trunc(v_stored) OR v_stored>2147483647 THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE=format('Bundle component quantity is incompatible with storage precision: %s',v_component.nombre);
    END IF;

    v_snapshot:=v_snapshot || jsonb_build_array(jsonb_build_object(
      'product_id',v_component.component_product_id,'name',v_component.nombre,
      'item_type',v_component.item_type,'quantity_per_bundle',v_component.quantity,
      'stored_quantity',v_stored::integer,'stock_scale',v_scale,'provider',v_component.proveedor
    ));

    IF v_component.item_type='stock_product' THEN
      PERFORM pg_advisory_xact_lock(v_component.component_product_id);
      SELECT ia.cantidad INTO v_stock
      FROM public.inventario_almacen ia
      WHERE ia.organization_id=NEW.organization_id AND ia.producto_id=v_component.component_product_id
        AND ia.almacen_id=NEW.almacen_id
      FOR UPDATE;
      IF NOT FOUND THEN
        IF COALESCE(v_component.permitir_sin_stock,false) THEN
          INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
          VALUES(NEW.organization_id,v_component.component_product_id,NEW.almacen_id,0)
          ON CONFLICT(organization_id,producto_id,almacen_id) DO NOTHING;
          v_stock:=0;
        ELSE
          RAISE EXCEPTION USING ERRCODE='23514', MESSAGE=format('No inventory exists for bundle component: %s',v_component.nombre);
        END IF;
      END IF;
      IF COALESCE(v_stock,0)<v_stored AND NOT COALESCE(v_component.permitir_sin_stock,false) THEN
        RAISE EXCEPTION USING ERRCODE='23514', MESSAGE=format('Insufficient stock for bundle component: %s',v_component.nombre);
      END IF;
      UPDATE public.inventario_almacen
      SET cantidad=COALESCE(cantidad,0)-v_stored::integer
      WHERE organization_id=NEW.organization_id AND producto_id=v_component.component_product_id
        AND almacen_id=NEW.almacen_id
      RETURNING cantidad INTO v_saldo;

      INSERT INTO public.inventario_movimientos(
        organization_id,fecha,producto_id,producto_nombre,pcs,proveedor,tipo,saldo,
        almacen_id,almacen_nombre,observaciones,salida_cant,salida_und,salida_cliente,
        salida_p_unit,salida_total,venta_id,venta_id_original,vendedor_id,vendedor_nombre_snapshot,
        tipo_venta_snapshot,unidad_base_snapshot,request_id,stock_scale_snapshot
      )
      SELECT NEW.organization_id,COALESCE(v_date,now()),v_component.component_product_id,v_component.nombre,1,
        v_component.proveedor,'SALIDA',v_saldo,NEW.almacen_id,a.nombre,
        'Componente bundle · Venta #'||NEW.venta_id,v_stored::integer,
        CASE WHEN v_scale>1 THEN 'Base' ELSE 'Unidad' END,v_customer,0,0,
        NEW.venta_id,NEW.venta_id,v_seller_id,v_seller_name,'BUNDLE_COMPONENT',
        CASE WHEN v_scale>1 THEN 'Base' ELSE 'Unidad' END,v_request_id,v_scale
      FROM public.almacenes a
      WHERE a.organization_id=NEW.organization_id AND a.id=NEW.almacen_id;
    END IF;
  END LOOP;

  NEW.bundle_components_snapshot:=v_snapshot;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.consume_bundle_components_on_sale_detail() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER detalle_ventas_consume_bundle_components
BEFORE INSERT ON public.detalle_ventas
FOR EACH ROW EXECUTE FUNCTION private.consume_bundle_components_on_sale_detail();

-- -----------------------------------------------------------------------------
-- 5. Restauración reversible en anulación. Sólo se activa cuando la anulación ya
-- dejó evidencia en ventas_requests_anulados; un DELETE ordinario no repone stock.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.restore_bundle_components_on_cancelled_detail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cancel public.ventas_requests_anulados%ROWTYPE;
  v_component jsonb;
  v_product_id bigint;
  v_quantity integer;
  v_scale integer;
  v_saldo integer;
  v_name text;
  v_provider text;
  v_warehouse text;
BEGIN
  IF OLD.bundle_components_snapshot IS NULL OR jsonb_typeof(OLD.bundle_components_snapshot)<>'array' THEN RETURN OLD; END IF;
  SELECT * INTO v_cancel
  FROM public.ventas_requests_anulados r
  WHERE r.organization_id=OLD.organization_id AND r.venta_id_original=OLD.venta_id
  ORDER BY r.anulada_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN OLD; END IF;

  SELECT a.nombre INTO v_warehouse FROM public.almacenes a
  WHERE a.organization_id=OLD.organization_id AND a.id=OLD.almacen_id;

  FOR v_component IN SELECT value FROM jsonb_array_elements(OLD.bundle_components_snapshot)
  LOOP
    IF v_component->>'item_type'<>'stock_product' THEN CONTINUE; END IF;
    v_product_id:=(v_component->>'product_id')::bigint;
    v_quantity:=(v_component->>'stored_quantity')::integer;
    v_scale:=COALESCE(NULLIF(v_component->>'stock_scale','')::integer,1);
    v_name:=COALESCE(v_component->>'name','Componente');
    v_provider:=COALESCE(v_component->>'provider','Generico');
    PERFORM pg_advisory_xact_lock(v_product_id);
    INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
    VALUES(OLD.organization_id,v_product_id,OLD.almacen_id,v_quantity)
    ON CONFLICT(organization_id,producto_id,almacen_id)
    DO UPDATE SET cantidad=public.inventario_almacen.cantidad+EXCLUDED.cantidad
    RETURNING cantidad INTO v_saldo;

    INSERT INTO public.inventario_movimientos(
      organization_id,fecha,producto_id,producto_nombre,pcs,proveedor,tipo,saldo,
      almacen_id,almacen_nombre,observaciones,ingreso_cant,ingreso_und,ingreso_p_unit,
      venta_id,venta_id_original,vendedor_id,vendedor_nombre_snapshot,
      anulado_por_id,anulado_por_nombre_snapshot,motivo_anulacion,
      tipo_venta_snapshot,unidad_base_snapshot,request_id,stock_scale_snapshot
    ) VALUES(
      OLD.organization_id,clock_timestamp(),v_product_id,v_name,1,v_provider,'ANULACION_VENTA',v_saldo,
      OLD.almacen_id,COALESCE(v_warehouse,''),'Reposición componente bundle · Anulación Venta #'||OLD.venta_id,
      v_quantity,CASE WHEN v_scale>1 THEN 'Base' ELSE 'Unidad' END,0,
      OLD.venta_id,OLD.venta_id,v_cancel.vendedor_id_original,v_cancel.vendedor_nombre_snapshot,
      v_cancel.anulada_por_empleado_id,v_cancel.anulada_por_nombre_snapshot,v_cancel.motivo,
      'BUNDLE_COMPONENT',CASE WHEN v_scale>1 THEN 'Base' ELSE 'Unidad' END,v_cancel.request_id,v_scale
    );
  END LOOP;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION private.restore_bundle_components_on_cancelled_detail() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER detalle_ventas_restore_bundle_components
BEFORE DELETE ON public.detalle_ventas
FOR EACH ROW EXECUTE FUNCTION private.restore_bundle_components_on_cancelled_detail();

COMMIT;