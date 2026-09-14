-- F6.4: configuración del asistente queda registrada en audit_logs.
BEGIN;

CREATE OR REPLACE FUNCTION private.audit_business_assistant_settings_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
BEGIN
  PERFORM private.write_audit_log(
    NEW.organization_id,
    'assistant.settings.updated',
    'business_assistant_settings',
    NEW.organization_id::text,
    'UPDATE',
    'CONFIGURATION',
    NULL,
    jsonb_build_object(
      'old',jsonb_build_object(
        'enabled',OLD.enabled,
        'max_result_items',OLD.max_result_items,
        'default_period_days',OLD.default_period_days,
        'revision',OLD.revision
      ),
      'new',jsonb_build_object(
        'enabled',NEW.enabled,
        'max_result_items',NEW.max_result_items,
        'default_period_days',NEW.default_period_days,
        'revision',NEW.revision
      )
    )
  );
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.audit_business_assistant_settings_change() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER business_assistant_settings_audit_change
AFTER UPDATE ON public.business_assistant_settings
FOR EACH ROW EXECUTE FUNCTION private.audit_business_assistant_settings_change();

COMMIT;
