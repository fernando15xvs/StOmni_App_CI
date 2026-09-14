-- Fase 6.3 SaaS: dashboard configurable tenant-aware por periodo y sucursal.
BEGIN;

ALTER TABLE public.business_metric_definitions
  ADD COLUMN organization_id uuid;

UPDATE public.business_metric_definitions d
SET organization_id=c.organization_id
FROM public.configuracion_negocio c
WHERE d.organization_id IS NULL
  AND d.business_id=c.id;

DO $backfill_guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.business_metric_definitions WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped business metric definitions remain';
  END IF;
END;
$backfill_guard$;

ALTER TABLE public.business_metric_definitions
  DROP CONSTRAINT IF EXISTS business_metric_definitions_pkey,
  DROP CONSTRAINT IF EXISTS business_metric_definitions_business_id_position_key,
  DROP CONSTRAINT IF EXISTS business_metric_definitions_business_id_fkey,
  DROP CONSTRAINT IF EXISTS business_metric_definitions_source_key_check,
  ALTER COLUMN organization_id SET NOT NULL,
  ADD CONSTRAINT business_metric_definitions_organization_fkey
    FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE,
  ADD CONSTRAINT business_metric_definitions_pkey PRIMARY KEY(organization_id,source_key),
  ADD CONSTRAINT business_metric_definitions_organization_position_key UNIQUE(organization_id,position),
  ADD CONSTRAINT business_metric_definitions_source_key_check CHECK(source_key IN (
    'income','expenses','net_cash_flow','discounts','sales_count',
    'inventory_entries','inventory_exits','sales_revenue','gross_margin',
    'inventory_turnover','dead_inventory_items','accounts_receivable',
    'cash_performance_percent'
  ));

ALTER TABLE public.business_metric_definitions DROP COLUMN business_id;
CREATE INDEX business_metric_definitions_org_enabled_idx
  ON public.business_metric_definitions(organization_id,enabled,position);

-- Nuevos KPIs. Margen/rotación quedan deshabilitados hasta existir costo histórico
-- inmutable por línea de venta; F6.3 nunca usa el costo actual como costo histórico.
INSERT INTO public.business_metric_definitions(organization_id,source_key,label,position,enabled,format)
SELECT o.id,d.source_key,d.label,d.position,d.enabled,d.format
FROM public.organizations o
CROSS JOIN (VALUES
  ('sales_revenue','Ventas',7,true,'currency'),
  ('accounts_receivable','Cuentas por cobrar',8,true,'currency'),
  ('dead_inventory_items','Inventario inmovilizado',9,true,'number'),
  ('cash_performance_percent','Rendimiento de caja',10,true,'number'),
  ('gross_margin','Margen bruto',11,false,'currency'),
  ('inventory_turnover','Rotación de inventario',12,false,'number')
) AS d(source_key,label,position,enabled,format)
ON CONFLICT(organization_id,source_key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.create_default_business_metrics()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
BEGIN
  INSERT INTO public.business_metric_definitions(organization_id,source_key,label,position,enabled,format)
  VALUES
    (NEW.id,'income','Ingresos',0,true,'currency'),
    (NEW.id,'expenses','Gastos',1,true,'currency'),
    (NEW.id,'net_cash_flow','Flujo neto',2,true,'currency'),
    (NEW.id,'discounts','Descuentos',3,true,'currency'),
    (NEW.id,'sales_count','Ventas realizadas',4,true,'number'),
    (NEW.id,'inventory_entries','Entradas de inventario',5,true,'number'),
    (NEW.id,'inventory_exits','Salidas de inventario',6,true,'number'),
    (NEW.id,'sales_revenue','Ventas',7,true,'currency'),
    (NEW.id,'accounts_receivable','Cuentas por cobrar',8,true,'currency'),
    (NEW.id,'dead_inventory_items','Inventario inmovilizado',9,true,'number'),
    (NEW.id,'cash_performance_percent','Rendimiento de caja',10,true,'number'),
    (NEW.id,'gross_margin','Margen bruto',11,false,'currency'),
    (NEW.id,'inventory_turnover','Rotación de inventario',12,false,'number')
  ON CONFLICT(organization_id,source_key) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.create_default_business_metrics() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER organizations_create_default_business_metrics
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION private.create_default_business_metrics();

-- Reescritura tenant-aware de los RPC de configuración legacy.
CREATE OR REPLACE FUNCTION public.list_business_metrics_v1()
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id();
BEGIN
  IF NOT public.app_tiene_permiso('reports.view_profit') THEN
    RAISE EXCEPTION 'No autorizado para consultar métricas' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  SELECT jsonb_build_object(
    'source',d.source_key,'label',d.label,'position',d.position,
    'enabled',d.enabled,'format',d.format
  )
  FROM public.business_metric_definitions d
  WHERE d.organization_id=v_org
  ORDER BY d.position,d.source_key;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_business_metrics_v1(p_definitions jsonb)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row jsonb;
  v_sources text[]:=ARRAY[]::text[];
  v_positions integer[]:=ARRAY[]::integer[];
  v_source text;
  v_label text;
  v_position integer;
  v_enabled boolean;
  v_format text;
BEGIN
  IF NOT public.app_tiene_permiso('business.configure') THEN
    RAISE EXCEPTION 'No autorizado para configurar métricas' USING ERRCODE='42501';
  END IF;
  IF p_definitions IS NULL OR jsonb_typeof(p_definitions)<>'array'
     OR jsonb_array_length(p_definitions)>13 THEN
    RAISE EXCEPTION 'Configuración de métricas inválida' USING ERRCODE='22023';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_definitions) LOOP
    v_source:=trim(coalesce(v_row->>'source',''));
    v_label:=trim(coalesce(v_row->>'label',''));
    v_position:=NULLIF(v_row->>'position','')::integer;
    v_enabled:=NULLIF(v_row->>'enabled','')::boolean;
    v_format:=trim(coalesce(v_row->>'format',''));
    IF v_source NOT IN (
         'income','expenses','net_cash_flow','discounts','sales_count',
         'inventory_entries','inventory_exits','sales_revenue','gross_margin',
         'inventory_turnover','dead_inventory_items','accounts_receivable',
         'cash_performance_percent'
       )
       OR v_source=ANY(v_sources) OR v_label='' OR length(v_label)>80
       OR v_position IS NULL OR v_position NOT BETWEEN 0 AND 100
       OR v_position=ANY(v_positions) OR v_enabled IS NULL
       OR v_format NOT IN ('currency','number') THEN
      RAISE EXCEPTION 'Definición de métrica inválida o duplicada' USING ERRCODE='22023';
    END IF;
    v_sources:=array_append(v_sources,v_source);
    v_positions:=array_append(v_positions,v_position);
  END LOOP;

  DELETE FROM public.business_metric_definitions WHERE organization_id=v_org;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_definitions) LOOP
    INSERT INTO public.business_metric_definitions(
      organization_id,source_key,label,position,enabled,format
    ) VALUES(
      v_org,trim(v_row->>'source'),trim(v_row->>'label'),
      (v_row->>'position')::integer,(v_row->>'enabled')::boolean,trim(v_row->>'format')
    );
  END LOOP;

  RETURN QUERY SELECT * FROM public.list_business_metrics_v1();
END;
$$;

-- Venta atribuible a una sucursal sólo si todas sus líneas con almacén pertenecen
-- inequívocamente a esa misma sucursal. Se evita repartir o duplicar ventas multi-sucursal.
CREATE OR REPLACE FUNCTION private.sale_belongs_unambiguously_to_branch(
  p_organization_id uuid,p_sale_id bigint,p_branch_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
  SELECT p_branch_id IS NULL OR (
    EXISTS(
      SELECT 1 FROM public.detalle_ventas d
      JOIN public.almacenes a ON a.organization_id=d.organization_id AND a.id=d.almacen_id
      WHERE d.organization_id=p_organization_id AND d.venta_id=p_sale_id AND a.branch_id=p_branch_id
    )
    AND NOT EXISTS(
      SELECT 1 FROM public.detalle_ventas d
      JOIN public.almacenes a ON a.organization_id=d.organization_id AND a.id=d.almacen_id
      WHERE d.organization_id=p_organization_id AND d.venta_id=p_sale_id AND a.branch_id<>p_branch_id
    )
  )
$$;
REVOKE ALL ON FUNCTION private.sale_belongs_unambiguously_to_branch(uuid,bigint,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_configurable_dashboard_v1(
  p_start timestamptz,
  p_end timestamptz,
  p_branch_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_metric record;
  v_value numeric;
  v_income numeric:=0;
  v_expenses numeric:=0;
  v_available boolean;
  v_note text;
  v_metrics jsonb:='[]'::jsonb;
  v_branch_name text;
BEGIN
  IF NOT public.app_tiene_permiso('reports.view_profit') THEN
    RAISE EXCEPTION 'No autorizado para consultar dashboard' USING ERRCODE='42501';
  END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end<=p_start
     OR p_end-p_start>interval '366 days' THEN
    RAISE EXCEPTION 'Periodo de dashboard inválido' USING ERRCODE='22023';
  END IF;
  IF p_branch_id IS NOT NULL THEN
    SELECT b.name INTO v_branch_name
    FROM public.branches b
    WHERE b.organization_id=v_org AND b.id=p_branch_id AND b.status='active';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Sucursal no disponible en la organización actual' USING ERRCODE='P0002';
    END IF;
  END IF;

  SELECT coalesce(sum(m.monto),0) INTO v_income
  FROM public.movimientos m
  WHERE m.organization_id=v_org AND m.tipo='ingreso'
    AND m.fecha>=p_start AND m.fecha<p_end
    AND (p_branch_id IS NULL OR EXISTS(
      SELECT 1 FROM public.cash_registers cr
      WHERE cr.organization_id=v_org AND cr.id=m.cash_register_id AND cr.branch_id=p_branch_id
    ));

  SELECT coalesce(sum(m.monto),0) INTO v_expenses
  FROM public.movimientos m
  WHERE m.organization_id=v_org AND m.tipo='egreso'
    AND m.fecha>=p_start AND m.fecha<p_end
    AND (p_branch_id IS NULL OR EXISTS(
      SELECT 1 FROM public.cash_registers cr
      WHERE cr.organization_id=v_org AND cr.id=m.cash_register_id AND cr.branch_id=p_branch_id
    ));

  FOR v_metric IN
    SELECT d.* FROM public.business_metric_definitions d
    WHERE d.organization_id=v_org AND d.enabled
    ORDER BY d.position,d.source_key
  LOOP
    v_value:=0; v_available:=true; v_note:=NULL;
    CASE v_metric.source_key
      WHEN 'income' THEN
        v_value:=v_income;
        IF p_branch_id IS NOT NULL THEN v_note:='Sólo movimientos financieros atribuibles a cajas de la sucursal.'; END IF;
      WHEN 'expenses' THEN
        v_value:=v_expenses;
        IF p_branch_id IS NOT NULL THEN v_note:='Sólo movimientos financieros atribuibles a cajas de la sucursal.'; END IF;
      WHEN 'net_cash_flow' THEN
        v_value:=v_income-v_expenses;
        IF p_branch_id IS NOT NULL THEN v_note:='Sólo movimientos financieros atribuibles a cajas de la sucursal.'; END IF;
      WHEN 'cash_performance_percent' THEN
        v_value:=CASE WHEN v_income=0 THEN 0 ELSE ((v_income-v_expenses)/v_income)*100 END;
        IF p_branch_id IS NOT NULL THEN v_note:='Rendimiento sobre movimientos atribuibles a cajas de la sucursal.'; END IF;
      WHEN 'sales_revenue' THEN
        SELECT coalesce(sum(v.total),0) INTO v_value FROM public.ventas v
        WHERE v.organization_id=v_org AND v.fecha>=p_start AND v.fecha<p_end
          AND private.sale_belongs_unambiguously_to_branch(v_org,v.id,p_branch_id);
      WHEN 'sales_count' THEN
        SELECT count(*)::numeric INTO v_value FROM public.ventas v
        WHERE v.organization_id=v_org AND v.fecha>=p_start AND v.fecha<p_end
          AND private.sale_belongs_unambiguously_to_branch(v_org,v.id,p_branch_id);
      WHEN 'discounts' THEN
        SELECT coalesce(sum(v.descuento),0) INTO v_value FROM public.ventas v
        WHERE v.organization_id=v_org AND v.fecha>=p_start AND v.fecha<p_end
          AND private.sale_belongs_unambiguously_to_branch(v_org,v.id,p_branch_id);
      WHEN 'accounts_receivable' THEN
        SELECT coalesce(sum(v.saldo),0) INTO v_value FROM public.ventas v
        WHERE v.organization_id=v_org AND v.estado='pendiente' AND coalesce(v.saldo,0)>0
          AND private.sale_belongs_unambiguously_to_branch(v_org,v.id,p_branch_id);
        v_note:='Saldo pendiente actual; no está limitado al periodo de creación de la venta.';
      WHEN 'inventory_entries' THEN
        SELECT count(*)::numeric INTO v_value
        FROM public.inventario_movimientos im
        JOIN public.almacenes a ON a.organization_id=im.organization_id AND a.id=im.almacen_id
        WHERE im.organization_id=v_org AND im.fecha>=p_start AND im.fecha<p_end
          AND coalesce(im.ingreso_cant,0)>0 AND (p_branch_id IS NULL OR a.branch_id=p_branch_id);
      WHEN 'inventory_exits' THEN
        SELECT count(*)::numeric INTO v_value
        FROM public.inventario_movimientos im
        JOIN public.almacenes a ON a.organization_id=im.organization_id AND a.id=im.almacen_id
        WHERE im.organization_id=v_org AND im.fecha>=p_start AND im.fecha<p_end
          AND coalesce(im.salida_cant,0)>0 AND (p_branch_id IS NULL OR a.branch_id=p_branch_id);
      WHEN 'dead_inventory_items' THEN
        SELECT count(DISTINCT ia.producto_id)::numeric INTO v_value
        FROM public.inventario_almacen ia
        JOIN public.almacenes a ON a.organization_id=ia.organization_id AND a.id=ia.almacen_id
        JOIN public.productos p ON p.organization_id=ia.organization_id AND p.id=ia.producto_id
        WHERE ia.organization_id=v_org AND ia.cantidad>0
          AND coalesce(p.item_type,'stock_product')='stock_product'
          AND (p_branch_id IS NULL OR a.branch_id=p_branch_id)
          AND NOT EXISTS(
            SELECT 1 FROM public.inventario_movimientos im
            WHERE im.organization_id=v_org AND im.producto_id=ia.producto_id
              AND im.fecha>=p_start AND im.fecha<p_end AND coalesce(im.salida_cant,0)>0
              AND (p_branch_id IS NULL OR im.almacen_id IN (
                SELECT a2.id FROM public.almacenes a2 WHERE a2.organization_id=v_org AND a2.branch_id=p_branch_id
              ))
          );
        v_note:='Cantidad de SKUs con stock y sin salidas en el periodo; no mezcla unidades físicas incompatibles.';
      WHEN 'gross_margin' THEN
        v_value:=NULL; v_available:=false;
        v_note:='No disponible hasta persistir costo histórico inmutable por línea de venta.';
      WHEN 'inventory_turnover' THEN
        v_value:=NULL; v_available:=false;
        v_note:='No disponible hasta disponer de COGS histórico y valoración promedio inmutable.';
      ELSE
        v_value:=NULL; v_available:=false; v_note:='Fuente de métrica no soportada.';
    END CASE;

    v_metrics:=v_metrics||jsonb_build_array(jsonb_build_object(
      'source',v_metric.source_key,'label',v_metric.label,'position',v_metric.position,
      'format',v_metric.format,'available',v_available,'value',v_value,'note',v_note
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'start',p_start,'end',p_end,'branch_id',p_branch_id,'branch_name',v_branch_name,
    'scope_note',CASE WHEN p_branch_id IS NULL THEN 'Organización completa'
      ELSE 'Sucursal: ventas sólo si su atribución es inequívoca; caja sólo si el movimiento tiene caja atribuida.' END,
    'metrics',v_metrics
  );
END;
$$;

REVOKE ALL ON FUNCTION public.list_business_metrics_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_business_metrics_v1(jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_business_metrics_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_business_metrics_v1(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid) TO authenticated;

COMMIT;
