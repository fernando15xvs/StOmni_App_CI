-- F7.5: wrapper público sólo service_role para que una Edge Function verificada
-- pueda entregar eventos normalizados sin exponer el schema private a PostgREST.
BEGIN;

CREATE OR REPLACE FUNCTION public.apply_billing_subscription_event_v1(
  p_provider_code text,p_event_id text,p_event_type text,p_payload_sha256 text,
  p_external_subscription_ref text,p_external_price_ref text,p_status text,
  p_period_start timestamptz DEFAULT NULL,p_period_end timestamptz DEFAULT NULL,
  p_cancel_at_period_end boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path=''
AS $$
  SELECT private.apply_billing_subscription_event_v1(
    p_provider_code,p_event_id,p_event_type,p_payload_sha256,
    p_external_subscription_ref,p_external_price_ref,p_status,
    p_period_start,p_period_end,p_cancel_at_period_end
  )
$$;

REVOKE ALL ON FUNCTION public.apply_billing_subscription_event_v1(
  text,text,text,text,text,text,text,timestamptz,timestamptz,boolean
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_billing_subscription_event_v1(
  text,text,text,text,text,text,text,timestamptz,timestamptz,boolean
) TO service_role;

COMMIT;
