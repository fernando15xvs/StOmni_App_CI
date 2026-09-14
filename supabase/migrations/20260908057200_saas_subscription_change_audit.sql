-- F7.4: cambios de plan/estado del tenant quedan en el ledger empresarial F6.1.
BEGIN;

CREATE OR REPLACE FUNCTION private.audit_organization_subscription_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.plan_id IS DISTINCT FROM OLD.plan_id
    OR NEW.status IS DISTINCT FROM OLD.status
    OR NEW.cancel_at_period_end IS DISTINCT FROM OLD.cancel_at_period_end
    OR NEW.current_period_start IS DISTINCT FROM OLD.current_period_start
    OR NEW.current_period_end IS DISTINCT FROM OLD.current_period_end
  ) THEN
    PERFORM private.write_audit_log(
      NEW.organization_id,
      'subscription.updated',
      'organization_subscription',
      NEW.organization_id::text,
      'organization_subscriptions',
      'UPDATE',
      NULL,
      jsonb_build_object(
        'old_plan_id',OLD.plan_id,
        'new_plan_id',NEW.plan_id,
        'old_status',OLD.status,
        'new_status',NEW.status,
        'cancel_at_period_end',NEW.cancel_at_period_end,
        'revision',NEW.revision
      )
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.audit_organization_subscription_change() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER organization_subscriptions_audit_change
AFTER UPDATE ON public.organization_subscriptions
FOR EACH ROW EXECUTE FUNCTION private.audit_organization_subscription_change();

COMMIT;
