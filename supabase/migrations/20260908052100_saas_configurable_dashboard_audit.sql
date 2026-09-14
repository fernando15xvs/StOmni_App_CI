-- F6.3: cambios de configuración del dashboard forman parte de la auditoría empresarial.
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
    v_org,v_action,'business_metric_definition',v_source,TG_OP,'CONFIGURATION',NULL,v_metadata
  );
  RETURN COALESCE(NEW,OLD);
END;
$$;
REVOKE ALL ON FUNCTION private.audit_business_metric_definition_change() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER business_metric_definitions_audit_change
AFTER INSERT OR UPDATE OR DELETE ON public.business_metric_definitions
FOR EACH ROW EXECUTE FUNCTION private.audit_business_metric_definition_change();

COMMIT;
