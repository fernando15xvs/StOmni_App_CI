-- F6.2 hardening: validador determinista de claves de configuración.
BEGIN;

CREATE OR REPLACE FUNCTION public.update_operational_alert_settings_v1(
  p_expected_revision bigint,
  p_settings jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row public.operational_alert_settings;
  v_unknown text[];
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Only tenant admin can update alert settings';
  END IF;
  IF p_expected_revision IS NULL OR p_expected_revision<1
     OR p_settings IS NULL OR jsonb_typeof(p_settings)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid alert settings payload';
  END IF;

  SELECT array_agg(x.key ORDER BY x.key)
  INTO v_unknown
  FROM jsonb_object_keys(p_settings) AS x(key)
  WHERE x.key NOT IN (
    'low_stock_enabled','expiry_enabled','expiry_warning_days',
    'debt_overdue_enabled','debt_overdue_days',
    'purchase_pending_enabled','purchase_pending_days',
    'cash_session_enabled','cash_session_max_hours'
  );
  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unknown alert setting';
  END IF;

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
    revision=s.revision+1,
    updated_at=clock_timestamp(),
    updated_by=auth.uid()
  WHERE s.organization_id=v_org AND s.revision=p_expected_revision
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Alert settings changed in another session';
  END IF;
  RETURN to_jsonb(v_row)-'organization_id'-'updated_by';
END;
$$;

REVOKE ALL ON FUNCTION public.update_operational_alert_settings_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.update_operational_alert_settings_v1(bigint,jsonb) TO authenticated;

COMMIT;
