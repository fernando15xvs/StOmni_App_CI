-- Fase 7.5: interfaz agnóstica de proveedor de pagos.
-- No integra Stripe/Mercado Pago/etc.; congela contratos idempotentes y mappings seguros.
BEGIN;

CREATE TABLE public.billing_provider_plan_prices (
  provider_code text NOT NULL CHECK(provider_code ~ '^[a-z][a-z0-9_-]{1,31}$'),
  external_price_ref text NOT NULL CHECK(length(btrim(external_price_ref)) BETWEEN 1 AND 200),
  plan_id uuid NOT NULL REFERENCES public.subscription_plans(id) ON DELETE RESTRICT,
  billing_interval text NOT NULL CHECK(billing_interval IN ('month','year','custom')),
  status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','inactive')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(provider_code,external_price_ref)
);

CREATE TABLE public.billing_provider_accounts (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  provider_code text NOT NULL CHECK(provider_code ~ '^[a-z][a-z0-9_-]{1,31}$'),
  external_customer_ref text NOT NULL CHECK(length(btrim(external_customer_ref)) BETWEEN 1 AND 200),
  external_subscription_ref text CHECK(external_subscription_ref IS NULL OR length(btrim(external_subscription_ref)) BETWEEN 1 AND 200),
  revision bigint NOT NULL DEFAULT 1 CHECK(revision>=1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(provider_code,external_customer_ref),
  UNIQUE(provider_code,external_subscription_ref)
);

CREATE TABLE public.billing_webhook_events (
  provider_code text NOT NULL CHECK(provider_code ~ '^[a-z][a-z0-9_-]{1,31}$'),
  event_id text NOT NULL CHECK(length(btrim(event_id)) BETWEEN 1 AND 200),
  event_type text NOT NULL CHECK(length(btrim(event_type)) BETWEEN 1 AND 120),
  payload_sha256 text NOT NULL CHECK(payload_sha256 ~ '^[0-9a-f]{64}$'),
  organization_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'received' CHECK(status IN ('received','processed','failed')),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  error_code text CHECK(error_code IS NULL OR length(error_code)<=120),
  PRIMARY KEY(provider_code,event_id)
);

ALTER TABLE public.billing_provider_plan_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_provider_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_webhook_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_provider_plan_prices,public.billing_provider_accounts,public.billing_webhook_events FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_my_billing_summary_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_subscription jsonb;
  v_provider text;
  v_bound boolean:=false;
BEGIN
  v_subscription:=public.get_my_subscription_v1();
  SELECT a.provider_code,true INTO v_provider,v_bound
  FROM public.billing_provider_accounts a WHERE a.organization_id=v_org;
  RETURN v_subscription||jsonb_build_object(
    'billing_provider',v_provider,
    'provider_account_bound',coalesce(v_bound,false)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_billing_summary_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_my_billing_summary_v1() TO authenticated;

CREATE OR REPLACE FUNCTION private.set_billing_plan_price_binding_v1(
  p_provider_code text,p_external_price_ref text,p_plan_code text,p_billing_interval text,p_active boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_plan uuid;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Privileged billing writer required'; END IF;
  SELECT id INTO v_plan FROM public.subscription_plans WHERE code=p_plan_code;
  IF v_plan IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unknown billing plan'; END IF;
  IF p_provider_code !~ '^[a-z][a-z0-9_-]{1,31}$' OR nullif(btrim(p_external_price_ref),'') IS NULL OR p_billing_interval NOT IN ('month','year','custom') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid billing price binding';
  END IF;
  INSERT INTO public.billing_provider_plan_prices(provider_code,external_price_ref,plan_id,billing_interval,status,updated_at)
  VALUES(p_provider_code,btrim(p_external_price_ref),v_plan,p_billing_interval,CASE WHEN p_active THEN 'active' ELSE 'inactive' END,now())
  ON CONFLICT(provider_code,external_price_ref) DO UPDATE
    SET plan_id=EXCLUDED.plan_id,billing_interval=EXCLUDED.billing_interval,status=EXCLUDED.status,updated_at=now();
END;
$$;

CREATE OR REPLACE FUNCTION private.bind_billing_provider_account_v1(
  p_organization_id uuid,p_provider_code text,p_external_customer_ref text,p_external_subscription_ref text,p_expected_revision bigint DEFAULT NULL
)
RETURNS public.billing_provider_accounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_row public.billing_provider_accounts;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Privileged billing writer required'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organizations o WHERE o.id=p_organization_id) THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Organization not found'; END IF;
  IF p_provider_code !~ '^[a-z][a-z0-9_-]{1,31}$' OR nullif(btrim(p_external_customer_ref),'') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid billing account binding';
  END IF;
  SELECT * INTO v_row FROM public.billing_provider_accounts WHERE organization_id=p_organization_id FOR UPDATE;
  IF FOUND THEN
    IF p_expected_revision IS NULL OR p_expected_revision<>v_row.revision THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Billing account revision conflict'; END IF;
    UPDATE public.billing_provider_accounts a SET
      provider_code=p_provider_code,external_customer_ref=btrim(p_external_customer_ref),
      external_subscription_ref=nullif(btrim(p_external_subscription_ref),''),revision=a.revision+1,updated_at=now()
    WHERE a.organization_id=p_organization_id RETURNING a.* INTO v_row;
  ELSE
    IF p_expected_revision IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Billing account does not exist yet'; END IF;
    INSERT INTO public.billing_provider_accounts(organization_id,provider_code,external_customer_ref,external_subscription_ref)
    VALUES(p_organization_id,p_provider_code,btrim(p_external_customer_ref),nullif(btrim(p_external_subscription_ref),'')) RETURNING * INTO v_row;
  END IF;
  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION private.apply_billing_subscription_event_v1(
  p_provider_code text,p_event_id text,p_event_type text,p_payload_sha256 text,
  p_external_subscription_ref text,p_external_price_ref text,p_status text,
  p_period_start timestamptz DEFAULT NULL,p_period_end timestamptz DEFAULT NULL,p_cancel_at_period_end boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid;
  v_plan_code text;
  v_revision bigint;
  v_rows integer;
  v_error text;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Verified billing webhook context required'; END IF;
  IF p_payload_sha256 !~ '^[0-9a-f]{64}$' OR nullif(btrim(p_event_id),'') IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid billing event identity'; END IF;

  INSERT INTO public.billing_webhook_events(provider_code,event_id,event_type,payload_sha256)
  VALUES(p_provider_code,btrim(p_event_id),btrim(p_event_type),p_payload_sha256)
  ON CONFLICT(provider_code,event_id) DO NOTHING;
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows=0 THEN
    RETURN jsonb_build_object('processed',false,'duplicate',true,'error_code',NULL);
  END IF;

  BEGIN
    SELECT a.organization_id INTO v_org
    FROM public.billing_provider_accounts a
    WHERE a.provider_code=p_provider_code AND a.external_subscription_ref=p_external_subscription_ref;
    IF v_org IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Billing subscription binding not found'; END IF;

    SELECT p.code INTO v_plan_code
    FROM public.billing_provider_plan_prices bp
    JOIN public.subscription_plans p ON p.id=bp.plan_id
    WHERE bp.provider_code=p_provider_code AND bp.external_price_ref=p_external_price_ref AND bp.status='active';
    IF v_plan_code IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Billing price mapping not found'; END IF;

    SELECT revision INTO v_revision FROM public.organization_subscriptions WHERE organization_id=v_org FOR UPDATE;
    IF v_revision IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Organization subscription not found'; END IF;
    PERFORM private.set_organization_subscription_v1(
      v_org,v_plan_code,p_status,'billing_sync',v_revision,p_period_start,p_period_end,p_cancel_at_period_end
    );

    UPDATE public.billing_webhook_events SET organization_id=v_org,status='processed',processed_at=now(),error_code=NULL
    WHERE provider_code=p_provider_code AND event_id=p_event_id;
    RETURN jsonb_build_object('processed',true,'duplicate',false,'error_code',NULL);
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLSTATE;
    UPDATE public.billing_webhook_events SET organization_id=v_org,status='failed',processed_at=now(),error_code=v_error
    WHERE provider_code=p_provider_code AND event_id=p_event_id;
    RETURN jsonb_build_object('processed',false,'duplicate',false,'error_code',v_error);
  END;
END;
$$;

REVOKE ALL ON FUNCTION private.set_billing_plan_price_binding_v1(text,text,text,text,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.bind_billing_provider_account_v1(uuid,text,text,text,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.apply_billing_subscription_event_v1(text,text,text,text,text,text,text,timestamptz,timestamptz,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.set_billing_plan_price_binding_v1(text,text,text,text,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION private.bind_billing_provider_account_v1(uuid,text,text,text,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION private.apply_billing_subscription_event_v1(text,text,text,text,text,text,text,timestamptz,timestamptz,boolean) TO service_role;

COMMIT;
