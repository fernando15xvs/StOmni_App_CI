-- Fix business assistant settings audit trigger: source_table and
-- source_operation parameters were reversed/invalid, causing 23514 on UPDATE.
-- Keep the trigger/security model and audit metadata unchanged.
CREATE OR REPLACE FUNCTION private.audit_business_assistant_settings_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  PERFORM private.write_audit_log(
    NEW.organization_id,
    'assistant.settings.updated',
    'business_assistant_settings',
    NEW.organization_id::text,
    'business_assistant_settings',
    'UPDATE',
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
$function$;
