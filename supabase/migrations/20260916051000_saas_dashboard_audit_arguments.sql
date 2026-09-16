-- F6.3 hardening: preserve the audit writer argument contract for dashboard
-- metric changes. The original trigger accidentally swapped source_table and
-- source_operation, causing organization bootstrap to fail its first default
-- metric with audit_logs_source_operation_check.
BEGIN;

CREATE OR REPLACE FUNCTION private.audit_business_metric_definition_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=COALESCE(NEW.organization_id,OLD.organization_id);
  v_source text:=COALESCE(NEW.source_key,OLD.source_key);
  v_action text:=CASE TG_OP WHEN 'INSERT' THEN 'dashboard.metric.created' WHEN 'UPDATE' THEN 'dashboard.metric.updated' ELSE 'dashboard.metric.deleted' END;
  v_metadata jsonb;
BEGIN
  v_metadata:=jsonb_build_object(
    'source',v_source,
    'old',CASE WHEN TG_OP='INSERT' THEN NULL ELSE jsonb_build_object(
      'label',OLD.label,'position',OLD.position,'enabled',OLD.enabled,'format',OLD.format
    ) END,
    'new',CASE WHEN TG_OP='DELETE' THEN NULL ELSE jsonb_build_object(
      'label',NEW.label,'position',NEW.position,'enabled',NEW.enabled,'format',NEW.format
    ) END
  );
  PERFORM private.write_audit_log(
    v_org,v_action,'business_metric_definition',v_source,
    TG_TABLE_NAME,TG_OP,NULL,v_metadata
  );
  RETURN COALESCE(NEW,OLD);
END;
$$;

REVOKE ALL ON FUNCTION private.audit_business_metric_definition_change()
  FROM PUBLIC,anon,authenticated;

COMMIT;
