-- F6.2: reemplazo tenant-aware/event-driven de la alerta legacy de stock bajo.
BEGIN;

CREATE OR REPLACE FUNCTION private.refresh_low_stock_alert_for_product(
  p_organization_id uuid,
  p_product_id bigint,
  p_detected_at timestamptz DEFAULT clock_timestamp()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_enabled boolean;
  v_inventory_enabled boolean;
  v_name text;
  v_minimum numeric;
  v_total numeric;
  v_item_type text;
BEGIN
  SELECT s.low_stock_enabled INTO v_enabled
  FROM public.operational_alert_settings s
  WHERE s.organization_id=p_organization_id;

  SELECT coalesce(b.inventory_enabled,true) INTO v_inventory_enabled
  FROM public.business_capabilities b
  WHERE b.organization_id=p_organization_id;

  SELECT p.nombre,p.stock_minimo,coalesce(p.item_type,'stock_product')
  INTO v_name,v_minimum,v_item_type
  FROM public.productos p
  WHERE p.organization_id=p_organization_id AND p.id=p_product_id AND coalesce(p.activo,true);

  IF NOT FOUND OR coalesce(v_enabled,false)=false OR coalesce(v_inventory_enabled,false)=false
     OR v_item_type<>'stock_product' OR coalesce(v_minimum,0)<=0 THEN
    UPDATE public.operational_alerts
    SET status='resolved',resolved_at=p_detected_at,resolved_by=NULL,updated_at=p_detected_at
    WHERE organization_id=p_organization_id AND dedup_key='stock_low:product:'||p_product_id AND status<>'resolved';
    RETURN;
  END IF;

  SELECT coalesce(sum(ia.cantidad),0)::numeric INTO v_total
  FROM public.inventario_almacen ia
  WHERE ia.organization_id=p_organization_id AND ia.producto_id=p_product_id;

  IF v_total<=v_minimum THEN
    PERFORM private.upsert_operational_alert(
      p_organization_id,'stock_low',CASE WHEN v_total<=0 THEN 'critical' ELSE 'warning' END,
      'stock_low:product:'||p_product_id,'product',p_product_id::text,
      'Stock bajo: '||v_name,'Stock actual '||v_total||' / mínimo '||v_minimum,NULL,
      jsonb_build_object('product_id',p_product_id,'stock_total',v_total,'stock_minimum',v_minimum),p_detected_at
    );
  ELSE
    UPDATE public.operational_alerts
    SET status='resolved',resolved_at=p_detected_at,resolved_by=NULL,updated_at=p_detected_at
    WHERE organization_id=p_organization_id AND dedup_key='stock_low:product:'||p_product_id AND status<>'resolved';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.refresh_low_stock_alert_for_product(uuid,bigint,timestamptz) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.operational_stock_alert_deferred_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid;
  v_product bigint;
BEGIN
  IF TG_OP='DELETE' THEN
    v_org:=OLD.organization_id;
    v_product:=OLD.producto_id;
  ELSE
    v_org:=NEW.organization_id;
    v_product:=NEW.producto_id;
  END IF;
  PERFORM private.refresh_low_stock_alert_for_product(v_org,v_product,clock_timestamp());
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION private.operational_stock_alert_deferred_trigger() FROM PUBLIC,anon,authenticated;

CREATE CONSTRAINT TRIGGER operational_stock_alert_evaluate_tx
AFTER INSERT OR UPDATE OR DELETE ON public.inventario_almacen
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private.operational_stock_alert_deferred_trigger();

-- La configuración de automatizaciones también es configuración empresarial y
-- debe quedar trazada por F6.1. Sólo se registran los campos operativos allowlisted.
CREATE TRIGGER operational_alert_settings_audit_change
AFTER UPDATE ON public.operational_alert_settings
FOR EACH ROW EXECUTE FUNCTION private.audit_allowlisted_change_trigger(
  'configuration.alerts.changed','operational_alert_settings',
  'low_stock_enabled,expiry_enabled,expiry_warning_days,debt_overdue_enabled,debt_overdue_days,purchase_pending_enabled,purchase_pending_days,cash_session_enabled,cash_session_max_hours,revision'
);

COMMIT;
