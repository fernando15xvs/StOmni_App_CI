-- Fase 5.2 correcciones: transiciones seguras, compatibilidad de constraints y
-- fail-closed para trazabilidad/fiscal que aún no tiene reversión de bundles.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Normalización + transición segura de item_type.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.normalize_catalog_item_type()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
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
    NEW.tipo_venta:='unidad';
  ELSIF v_target_type='bundle' THEN
    NEW.unidad_medida:='Unidad';
    NEW.cantidad_por_caja:=1;
    NEW.tipo_venta:='unidad';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.normalize_catalog_item_type() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.set_catalog_item_type_v1(
  p_product_id bigint,
  p_item_type text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_type text:=lower(btrim(COALESCE(p_item_type,'')));
  v_row public.productos;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant administrator permission required';
  END IF;
  IF v_type NOT IN ('stock_product','non_stock_product','service','bundle') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported catalog item type';
  END IF;

  SELECT * INTO v_row
  FROM public.productos p
  WHERE p.organization_id=v_org AND p.id=p_product_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Catalog item not available in current organization';
  END IF;

  UPDATE public.productos
  SET item_type=v_type,es_servicio=(v_type='service')
  WHERE organization_id=v_org AND id=p_product_id
  RETURNING * INTO v_row;

  IF v_type<>'stock_product' THEN
    UPDATE public.inventario_almacen
    SET cantidad=0
    WHERE organization_id=v_org AND producto_id=p_product_id;
  END IF;

  RETURN jsonb_build_object(
    'id',v_row.id,'item_type',v_row.item_type,'is_service',v_row.es_servicio,
    'active',COALESCE(v_row.activo,true)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_catalog_item_type_v1(bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_catalog_item_type_v1(bigint,text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Los componentes stock trazables quedan bloqueados en bundles V1.
-- La venta trazable actual consume sólo los productos presentes en p_detalles;
-- consumir lotes/series de componentes exige un contrato de selección adicional.
-- -----------------------------------------------------------------------------
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
  v_trace_mode text;
BEGIN
  NEW.organization_id:=v_org;
  SELECT item_type INTO v_bundle_type
  FROM public.productos
  WHERE organization_id=v_org AND id=NEW.bundle_product_id AND COALESCE(activo,true)
  FOR SHARE;
  IF v_bundle_type IS DISTINCT FROM 'bundle' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundle component parent must be an active bundle';
  END IF;

  SELECT p.item_type,COALESCE(t.mode,'none')
  INTO v_component_type,v_trace_mode
  FROM public.productos p
  LEFT JOIN public.product_traceability_configs t
    ON t.organization_id=p.organization_id AND t.product_id=p.id
  WHERE p.organization_id=v_org AND p.id=NEW.component_product_id AND COALESCE(p.activo,true)
  FOR SHARE OF p;
  IF v_component_type IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Bundle component is not available in current organization';
  END IF;
  IF v_component_type='bundle' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Nested bundles are not supported';
  END IF;
  IF v_component_type='stock_product' AND v_trace_mode<>'none' THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Traceable stock products are not supported as bundle components in catalog V1';
  END IF;
  NEW.updated_at:=clock_timestamp();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.validate_bundle_component() FROM PUBLIC,anon,authenticated;

-- A product that becomes traceable cannot remain inside an existing bundle.
CREATE OR REPLACE FUNCTION private.block_traceability_for_bundle_component()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.mode<>'none' AND EXISTS(
    SELECT 1 FROM public.bundle_components bc
    WHERE bc.organization_id=NEW.organization_id AND bc.component_product_id=NEW.product_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Remove product from bundles before enabling lot/serial traceability';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.block_traceability_for_bundle_component() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS zz_traceability_not_bundle_component ON public.product_traceability_configs;
CREATE TRIGGER zz_traceability_not_bundle_component
BEFORE INSERT OR UPDATE OF mode ON public.product_traceability_configs
FOR EACH ROW EXECUTE FUNCTION private.block_traceability_for_bundle_component();

-- -----------------------------------------------------------------------------
-- 3. Corrige el target de ON CONFLICT al contrato histórico preservado en F3.4:
-- producto_id y almacen_id siguen siendo globalmente únicos en esta versión.
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
    ON CONFLICT(producto_id,almacen_id)
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

-- Reemplaza sólo la función de consumo para corregir el INSERT de fila cero y
-- bloquear bundles en boleta/factura hasta tener devolución parcial fiscal.
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
  v_document_type text;
BEGIN
  SELECT p.item_type INTO v_type
  FROM public.productos p
  WHERE p.organization_id=NEW.organization_id AND p.id=NEW.producto_id;
  IF v_type IS DISTINCT FROM 'bundle' THEN RETURN NEW; END IF;
  IF lower(btrim(COALESCE(NEW.tipo_unidad,'unidad')))<>'unidad' THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundles are sold by unit in catalog V1';
  END IF;

  SELECT v.request_id,COALESCE(c.nombre,'CLIENTE GENERAL'),v.vendedor_id,e.nombre,v.fecha,
         lower(btrim(COALESCE(v.tipo_comprobante_solicitado,'ticket_interno')))
  INTO v_request_id,v_customer,v_seller_id,v_seller_name,v_date,v_document_type
  FROM public.ventas v
  LEFT JOIN public.clientes c ON c.organization_id=v.organization_id AND c.id=v.cliente_id
  LEFT JOIN public.empleados e ON e.organization_id=v.organization_id AND e.id=v.vendedor_id
  WHERE v.organization_id=NEW.organization_id AND v.id=NEW.venta_id;

  IF v_document_type IN ('boleta','factura') THEN
    RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE='Bundles are temporarily limited to internal tickets until electronic credit-note component reversal is implemented';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.bundle_components bc
    WHERE bc.organization_id=NEW.organization_id AND bc.bundle_product_id=NEW.producto_id
  ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Bundle has no configured components'; END IF;

  FOR v_component IN
    SELECT bc.component_product_id,bc.quantity,p.nombre,p.item_type,p.permitir_sin_stock,
           COALESCE(pr.nombre,'Generico') proveedor,
           COALESCE(up.profile,'{}'::jsonb) profile,
           COALESCE(tc.mode,'none') trace_mode
    FROM public.bundle_components bc
    JOIN public.productos p ON p.organization_id=bc.organization_id AND p.id=bc.component_product_id
    LEFT JOIN public.proveedores pr ON pr.organization_id=p.organization_id AND pr.id=p.proveedor_id
    LEFT JOIN public.product_unit_profiles up ON up.organization_id=p.organization_id AND up.product_id=p.id
    LEFT JOIN public.product_traceability_configs tc ON tc.organization_id=p.organization_id AND tc.product_id=p.id
    WHERE bc.organization_id=NEW.organization_id AND bc.bundle_product_id=NEW.producto_id
    ORDER BY bc.component_product_id
  LOOP
    IF v_component.item_type='stock_product' AND v_component.trace_mode<>'none' THEN
      RAISE EXCEPTION USING ERRCODE='0A000', MESSAGE=format('Traceable bundle component is not supported: %s',v_component.nombre);
    END IF;
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
          ON CONFLICT(producto_id,almacen_id) DO NOTHING;
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

-- Corrige retorno de record para DELETE en el guard de capacidad de inventario.
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
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF NOT COALESCE((SELECT b.inventory_enabled FROM public.business_capabilities b WHERE b.organization_id=v_org),false) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory capability is disabled';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_inventory_capability() FROM PUBLIC,anon,authenticated;

COMMIT;