-- Fase 6.2 SaaS: inbox tenant-aware de alertas y automatizaciones operativas.
BEGIN;

-- El trigger OneSignal legacy apuntaba a included_segments=All y no es válido
-- en un producto multi-tenant. Se retira antes de instalar el inbox aislado.
DROP TRIGGER IF EXISTS trigger_stock_alert_evaluar_tx ON public.inventario_almacen;
DROP TRIGGER IF EXISTS trigger_stock_alert_acumular_tx ON public.inventario_almacen;

CREATE TABLE public.operational_alert_settings (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  low_stock_enabled boolean NOT NULL DEFAULT true,
  expiry_enabled boolean NOT NULL DEFAULT true,
  expiry_warning_days integer NOT NULL DEFAULT 30 CHECK(expiry_warning_days BETWEEN 1 AND 365),
  debt_overdue_enabled boolean NOT NULL DEFAULT true,
  debt_overdue_days integer NOT NULL DEFAULT 30 CHECK(debt_overdue_days BETWEEN 1 AND 3650),
  purchase_pending_enabled boolean NOT NULL DEFAULT true,
  purchase_pending_days integer NOT NULL DEFAULT 7 CHECK(purchase_pending_days BETWEEN 1 AND 365),
  cash_session_enabled boolean NOT NULL DEFAULT true,
  cash_session_max_hours integer NOT NULL DEFAULT 16 CHECK(cash_session_max_hours BETWEEN 1 AND 168),
  revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

INSERT INTO public.operational_alert_settings(organization_id)
SELECT id FROM public.organizations
ON CONFLICT(organization_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.create_default_operational_alert_settings()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO public.operational_alert_settings(organization_id)
  VALUES(NEW.id) ON CONFLICT(organization_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.create_default_operational_alert_settings() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER organizations_create_operational_alert_settings
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION private.create_default_operational_alert_settings();

CREATE TABLE public.operational_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  category text NOT NULL CHECK(category IN ('stock_low','expiry','debt_overdue','purchase_pending','cash_session_open','task')),
  severity text NOT NULL DEFAULT 'warning' CHECK(severity IN ('info','warning','critical')),
  status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','acknowledged','resolved')),
  dedup_key text NOT NULL CHECK(char_length(dedup_key) BETWEEN 3 AND 240),
  entity_type text,
  entity_id text,
  title text NOT NULL CHECK(btrim(title)<>'' AND char_length(title)<=160),
  message text NOT NULL CHECK(btrim(message)<>'' AND char_length(message)<=1000),
  due_at timestamptz,
  first_detected_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_detected_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  resolved_at timestamptz,
  resolved_by uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(metadata)='object' AND pg_column_size(metadata)<=16384),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(organization_id,dedup_key)
);

CREATE INDEX operational_alerts_org_status_idx ON public.operational_alerts(organization_id,status,severity,last_detected_at DESC);
CREATE INDEX operational_alerts_org_category_idx ON public.operational_alerts(organization_id,category,status);
CREATE INDEX operational_alerts_due_idx ON public.operational_alerts(organization_id,due_at) WHERE status<>'resolved' AND due_at IS NOT NULL;

ALTER TABLE public.operational_alert_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operational_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.operational_alert_settings,public.operational_alerts FROM PUBLIC,anon,authenticated;

CREATE POLICY operational_alert_settings_tenant_read ON public.operational_alert_settings
FOR SELECT TO authenticated USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));
CREATE POLICY operational_alerts_tenant_read ON public.operational_alerts
FOR SELECT TO authenticated USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));

CREATE OR REPLACE FUNCTION private.upsert_operational_alert(
  p_organization_id uuid,p_category text,p_severity text,p_dedup_key text,
  p_entity_type text,p_entity_id text,p_title text,p_message text,
  p_due_at timestamptz,p_metadata jsonb,p_detected_at timestamptz
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.operational_alerts(
    organization_id,category,severity,status,dedup_key,entity_type,entity_id,
    title,message,due_at,first_detected_at,last_detected_at,metadata,updated_at
  ) VALUES(
    p_organization_id,p_category,p_severity,'open',p_dedup_key,p_entity_type,p_entity_id,
    left(p_title,160),left(p_message,1000),p_due_at,p_detected_at,p_detected_at,
    coalesce(p_metadata,'{}'::jsonb),p_detected_at
  )
  ON CONFLICT(organization_id,dedup_key) DO UPDATE SET
    category=EXCLUDED.category,severity=EXCLUDED.severity,
    status=CASE WHEN public.operational_alerts.status='resolved' THEN 'open' ELSE public.operational_alerts.status END,
    entity_type=EXCLUDED.entity_type,entity_id=EXCLUDED.entity_id,title=EXCLUDED.title,message=EXCLUDED.message,
    due_at=EXCLUDED.due_at,last_detected_at=EXCLUDED.last_detected_at,metadata=EXCLUDED.metadata,
    resolved_at=CASE WHEN public.operational_alerts.status='resolved' THEN NULL ELSE public.operational_alerts.resolved_at END,
    resolved_by=CASE WHEN public.operational_alerts.status='resolved' THEN NULL ELSE public.operational_alerts.resolved_by END,
    updated_at=EXCLUDED.updated_at
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION private.upsert_operational_alert(uuid,text,text,text,text,text,text,text,timestamptz,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.refresh_operational_alerts_for_org(p_organization_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_settings public.operational_alert_settings%ROWTYPE;
  v_run timestamptz:=clock_timestamp();
  v_row record;
  v_count integer:=0;
  v_inventory_enabled boolean:=true;
BEGIN
  SELECT * INTO v_settings FROM public.operational_alert_settings WHERE organization_id=p_organization_id;
  IF NOT FOUND THEN
    INSERT INTO public.operational_alert_settings(organization_id) VALUES(p_organization_id)
    ON CONFLICT(organization_id) DO NOTHING;
    SELECT * INTO v_settings FROM public.operational_alert_settings WHERE organization_id=p_organization_id;
  END IF;

  SELECT coalesce(b.inventory_enabled,true) INTO v_inventory_enabled
  FROM public.business_capabilities b WHERE b.organization_id=p_organization_id;

  IF v_settings.low_stock_enabled AND v_inventory_enabled THEN
    FOR v_row IN
      SELECT p.id,p.nombre,p.stock_minimo,coalesce(sum(ia.cantidad),0)::numeric AS stock_total
      FROM public.productos p
      LEFT JOIN public.inventario_almacen ia ON ia.organization_id=p.organization_id AND ia.producto_id=p.id
      WHERE p.organization_id=p_organization_id AND coalesce(p.activo,true)
        AND coalesce(p.item_type,'stock_product')='stock_product' AND coalesce(p.stock_minimo,0)>0
      GROUP BY p.id,p.nombre,p.stock_minimo
      HAVING coalesce(sum(ia.cantidad),0)<=p.stock_minimo
    LOOP
      PERFORM private.upsert_operational_alert(
        p_organization_id,'stock_low',CASE WHEN v_row.stock_total<=0 THEN 'critical' ELSE 'warning' END,
        'stock_low:product:'||v_row.id,'product',v_row.id::text,'Stock bajo: '||v_row.nombre,
        'Stock actual '||v_row.stock_total||' / mínimo '||v_row.stock_minimo,NULL,
        jsonb_build_object('product_id',v_row.id,'stock_total',v_row.stock_total,'stock_minimum',v_row.stock_minimo),v_run);
      v_count:=v_count+1;
    END LOOP;
  END IF;

  IF v_settings.expiry_enabled AND v_inventory_enabled THEN
    FOR v_row IN
      SELECT l.id,l.product_id,l.warehouse_id,l.lot_code,l.expiry_date,l.base_quantity,p.nombre
      FROM public.inventory_lots l
      JOIN public.productos p ON p.organization_id=l.organization_id AND p.id=l.product_id
      WHERE l.organization_id=p_organization_id AND l.base_quantity>0 AND l.expiry_date IS NOT NULL
        AND l.expiry_date<=((v_run AT TIME ZONE 'UTC')::date+v_settings.expiry_warning_days)
    LOOP
      PERFORM private.upsert_operational_alert(
        p_organization_id,'expiry',CASE WHEN v_row.expiry_date<(v_run AT TIME ZONE 'UTC')::date THEN 'critical' ELSE 'warning' END,
        'expiry:lot:'||v_row.id,'inventory_lot',v_row.id::text,'Lote próximo a vencer: '||v_row.nombre,
        'Lote '||v_row.lot_code||' vence el '||v_row.expiry_date::text,v_row.expiry_date::timestamp AT TIME ZONE 'UTC',
        jsonb_build_object('lot_id',v_row.id,'product_id',v_row.product_id,'warehouse_id',v_row.warehouse_id,'expiry_date',v_row.expiry_date,'base_quantity',v_row.base_quantity),v_run);
      v_count:=v_count+1;
    END LOOP;
  END IF;

  -- El esquema legacy de deuda no tiene fecha contractual de vencimiento. V1
  -- define "vencida" operativamente como saldo pendiente con antigüedad mayor al umbral configurado.
  IF v_settings.debt_overdue_enabled THEN
    FOR v_row IN
      SELECT v.id,v.cliente_id,v.fecha,v.saldo,c.nombre AS cliente_nombre
      FROM public.ventas v LEFT JOIN public.clientes c ON c.organization_id=v.organization_id AND c.id=v.cliente_id
      WHERE v.organization_id=p_organization_id AND v.estado='pendiente' AND coalesce(v.saldo,0)>0
        AND v.fecha<=v_run-make_interval(days=>v_settings.debt_overdue_days)
    LOOP
      PERFORM private.upsert_operational_alert(
        p_organization_id,'debt_overdue','warning','debt_overdue:sale:'||v_row.id,'sale',v_row.id::text,
        'Deuda pendiente: '||coalesce(v_row.cliente_nombre,'Cliente'),
        'Venta #'||v_row.id||' mantiene saldo '||v_row.saldo||' por más de '||v_settings.debt_overdue_days||' días',
        v_row.fecha+make_interval(days=>v_settings.debt_overdue_days),
        jsonb_build_object('sale_id',v_row.id,'customer_id',v_row.cliente_id,'balance',v_row.saldo,'age_threshold_days',v_settings.debt_overdue_days),v_run);
      v_count:=v_count+1;
    END LOOP;
  END IF;

  IF v_settings.purchase_pending_enabled THEN
    FOR v_row IN
      SELECT po.id,po.supplier_id,po.status,po.ordered_at,po.expected_at,s.nombre AS supplier_name
      FROM public.purchase_orders po
      JOIN public.proveedores s ON s.organization_id=po.organization_id AND s.id=po.supplier_id
      WHERE po.organization_id=p_organization_id AND po.status IN ('ordered','partially_received')
        AND coalesce(po.expected_at,po.ordered_at+make_interval(days=>v_settings.purchase_pending_days))<=v_run
    LOOP
      PERFORM private.upsert_operational_alert(
        p_organization_id,'purchase_pending','warning','purchase_pending:order:'||v_row.id,'purchase_order',v_row.id::text,
        'Compra pendiente: '||v_row.supplier_name,'Orden #'||v_row.id||' aún está pendiente de recepción',
        coalesce(v_row.expected_at,v_row.ordered_at+make_interval(days=>v_settings.purchase_pending_days)),
        jsonb_build_object('purchase_order_id',v_row.id,'supplier_id',v_row.supplier_id,'status',v_row.status),v_run);
      v_count:=v_count+1;
    END LOOP;
  END IF;

  IF v_settings.cash_session_enabled THEN
    FOR v_row IN
      SELECT sc.id,sc.cash_register_id,sc.branch_id,sc.fecha_apertura,cr.name AS register_name
      FROM public.sesiones_caja sc
      JOIN public.cash_registers cr ON cr.organization_id=sc.organization_id AND cr.id=sc.cash_register_id
      WHERE sc.organization_id=p_organization_id AND sc.estado='ABIERTA'
        AND sc.fecha_apertura<=v_run-make_interval(hours=>v_settings.cash_session_max_hours)
    LOOP
      PERFORM private.upsert_operational_alert(
        p_organization_id,'cash_session_open','warning','cash_session_open:session:'||v_row.id,'cash_session',v_row.id::text,
        'Caja abierta por tiempo prolongado: '||v_row.register_name,
        'La sesión de caja supera '||v_settings.cash_session_max_hours||' horas abierta',
        v_row.fecha_apertura+make_interval(hours=>v_settings.cash_session_max_hours),
        jsonb_build_object('cash_session_id',v_row.id,'cash_register_id',v_row.cash_register_id,'branch_id',v_row.branch_id,'opened_at',v_row.fecha_apertura),v_run);
      v_count:=v_count+1;
    END LOOP;
  END IF;

  UPDATE public.operational_alerts
  SET status='resolved',resolved_at=v_run,resolved_by=NULL,updated_at=v_run
  WHERE organization_id=p_organization_id
    AND category IN ('stock_low','expiry','debt_overdue','purchase_pending','cash_session_open')
    AND status<>'resolved' AND last_detected_at<v_run;

  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION private.refresh_operational_alerts_for_org(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.refresh_operational_alerts_v1()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_count integer;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to refresh alerts'; END IF;
  SELECT private.refresh_operational_alerts_for_org(v_org) INTO v_count;
  RETURN jsonb_build_object('success',true,'detected',v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.list_operational_alerts_v1(p_status text DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS SETOF jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_limit integer:=coalesce(p_limit,100); v_status text:=nullif(lower(btrim(coalesce(p_status,''))), '');
BEGIN
  IF NOT private.has_permission('tenant.read') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to read alerts'; END IF;
  IF v_limit<1 OR v_limit>200 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Alert page size must be between 1 and 200'; END IF;
  IF v_status IS NOT NULL AND v_status NOT IN ('open','acknowledged','resolved') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid alert status'; END IF;
  RETURN QUERY SELECT jsonb_build_object(
    'id',a.id,'category',a.category,'severity',a.severity,'status',a.status,'entity_type',a.entity_type,'entity_id',a.entity_id,
    'title',a.title,'message',a.message,'due_at',a.due_at,'first_detected_at',a.first_detected_at,'last_detected_at',a.last_detected_at,
    'acknowledged_at',a.acknowledged_at,'resolved_at',a.resolved_at,'metadata',a.metadata
  ) FROM public.operational_alerts a WHERE a.organization_id=v_org AND (v_status IS NULL OR a.status=v_status)
  ORDER BY CASE a.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END,a.due_at NULLS LAST,a.last_detected_at DESC LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.acknowledge_operational_alert_v1(p_alert_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.operational_alerts;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to acknowledge alerts'; END IF;
  UPDATE public.operational_alerts SET status=CASE WHEN status='resolved' THEN status ELSE 'acknowledged' END,
    acknowledged_at=CASE WHEN status='resolved' THEN acknowledged_at ELSE clock_timestamp() END,
    acknowledged_by=CASE WHEN status='resolved' THEN acknowledged_by ELSE auth.uid() END,updated_at=clock_timestamp()
  WHERE organization_id=v_org AND id=p_alert_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Alert not available in current organization'; END IF;
  RETURN jsonb_build_object('id',v_row.id,'status',v_row.status);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_operational_task_v1(p_title text,p_message text,p_due_at timestamptz DEFAULT NULL,p_severity text DEFAULT 'info')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_id uuid; v_severity text:=lower(btrim(coalesce(p_severity,'info')));
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only tenant admin can create operational tasks'; END IF;
  IF nullif(btrim(coalesce(p_title,'')),'') IS NULL OR char_length(btrim(p_title))>160 OR nullif(btrim(coalesce(p_message,'')),'') IS NULL OR char_length(btrim(p_message))>1000 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid operational task content';
  END IF;
  IF v_severity NOT IN ('info','warning','critical') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid task severity'; END IF;
  v_id:=gen_random_uuid();
  INSERT INTO public.operational_alerts(id,organization_id,category,severity,status,dedup_key,entity_type,entity_id,title,message,due_at,created_by)
  VALUES(v_id,v_org,'task',v_severity,'open','task:'||v_id,'task',v_id::text,btrim(p_title),btrim(p_message),p_due_at,auth.uid());
  RETURN jsonb_build_object('id',v_id,'status','open');
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_operational_alert_v1(p_alert_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.operational_alerts;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only tenant admin can resolve alerts manually'; END IF;
  UPDATE public.operational_alerts SET status='resolved',resolved_at=clock_timestamp(),resolved_by=auth.uid(),updated_at=clock_timestamp()
  WHERE organization_id=v_org AND id=p_alert_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Alert not available in current organization'; END IF;
  RETURN jsonb_build_object('id',v_row.id,'status',v_row.status);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_operational_alert_settings_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.operational_alert_settings;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to read alert settings'; END IF;
  SELECT * INTO v_row FROM public.operational_alert_settings WHERE organization_id=v_org;
  RETURN to_jsonb(v_row)-'organization_id'-'updated_by';
END;
$$;

CREATE OR REPLACE FUNCTION public.update_operational_alert_settings_v1(p_expected_revision bigint,p_settings jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_row public.operational_alert_settings; v_unknown text[];
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only tenant admin can update alert settings'; END IF;
  IF p_expected_revision IS NULL OR p_expected_revision<1 OR p_settings IS NULL OR jsonb_typeof(p_settings)<>'object' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid alert settings payload'; END IF;
  SELECT array_agg(key) INTO v_unknown FROM jsonb_object_keys(p_settings) key WHERE key NOT IN (
    'low_stock_enabled','expiry_enabled','expiry_warning_days','debt_overdue_enabled','debt_overdue_days',
    'purchase_pending_enabled','purchase_pending_days','cash_session_enabled','cash_session_max_hours');
  IF v_unknown IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unknown alert setting'; END IF;
  UPDATE public.operational_alert_settings s SET
    low_stock_enabled=coalesce((p_settings->>'low_stock_enabled')::boolean,s.low_stock_enabled),
    expiry_enabled=coalesce((p_settings->>'expiry_enabled')::boolean,s.expiry_enabled),
    expiry_warning_days=coalesce((p_settings->>'expiry_warning_days')::integer,s.expiry_warning_days),
    debt_overdue_enabled=coalesce((p_settings->>'debt_overdue_enabled')::boolean,s.debt_overdue_enabled),
    debt_overdue_days=coalesce((p_settings->>'debt_overdue_days')::integer,s.debt_overdue_days),
    purchase_pending_enabled=coalesce((p_settings->>'purchase_pending_enabled')::boolean,s.purchase_pending_enabled),
    purchase_pending_days=coalesce((p_settings->>'purchase_pending_days')::integer,s.purchase_pending_days),
    cash_session_enabled=coalesce((p_settings->>'cash_session_enabled')::boolean,s.cash_session_enabled),
    cash_session_max_hours=coalesce((p_settings->>'cash_session_max_hours')::integer,s.cash_session_max_hours),
    revision=s.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
  WHERE s.organization_id=v_org AND s.revision=p_expected_revision RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Alert settings changed in another session'; END IF;
  RETURN to_jsonb(v_row)-'organization_id'-'updated_by';
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_operational_alerts_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_operational_alerts_v1(text,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.acknowledge_operational_alert_v1(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.create_operational_task_v1(text,text,timestamptz,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.resolve_operational_alert_v1(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_operational_alert_settings_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_operational_alert_settings_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_operational_alerts_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_operational_alerts_v1(text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_operational_alert_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_operational_task_v1(text,text,timestamptz,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_operational_alert_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_operational_alert_settings_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_operational_alert_settings_v1(bigint,jsonb) TO authenticated;

COMMIT;
