-- Fase 7.2: una suscripción SaaS por organización.
-- Compatibilidad de rollout: tenants existentes/nuevos reciben Enterprise activa de transición.
-- F7.5 será responsable de sincronizar estados/proveedor de pagos; el cliente no muta esta tabla.
BEGIN;

CREATE TABLE public.organization_subscriptions (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  plan_id uuid NOT NULL REFERENCES public.subscription_plans(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('trialing','active','past_due','suspended','canceled')),
  assignment_reason text NOT NULL DEFAULT 'legacy_grandfathered'
    CHECK (assignment_reason IN ('legacy_grandfathered','bootstrap_default','admin_override','billing_sync')),
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (current_period_end IS NULL OR current_period_start IS NULL OR current_period_end > current_period_start)
);

ALTER TABLE public.organization_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.organization_subscriptions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.organization_subscriptions TO authenticated;

CREATE POLICY organization_subscriptions_tenant_read
ON public.organization_subscriptions
FOR SELECT TO authenticated
USING (private.row_belongs_to_current_organization(organization_id));

-- Rollout fail-safe: no se reducen capacidades por introducir monetización.
INSERT INTO public.organization_subscriptions(organization_id,plan_id,status,assignment_reason)
SELECT o.id,p.id,'active','legacy_grandfathered'
FROM public.organizations o
CROSS JOIN LATERAL (
  SELECT id FROM public.subscription_plans WHERE code='enterprise' AND status='active' LIMIT 1
) p
ON CONFLICT (organization_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.create_default_organization_subscription()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_plan uuid;
BEGIN
  SELECT id INTO v_plan FROM public.subscription_plans
  WHERE code='enterprise' AND status='active';
  IF v_plan IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Default SaaS plan is not available';
  END IF;
  INSERT INTO public.organization_subscriptions(
    organization_id,plan_id,status,assignment_reason
  ) VALUES(NEW.id,v_plan,'active','bootstrap_default')
  ON CONFLICT (organization_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.create_default_organization_subscription() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER organizations_create_default_subscription
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION private.create_default_organization_subscription();

CREATE OR REPLACE FUNCTION public.get_my_subscription_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'organization_id',s.organization_id,
    'plan_id',p.id,
    'plan_code',p.code,
    'plan_name',p.display_name,
    'status',s.status,
    'assignment_reason',s.assignment_reason,
    'current_period_start',s.current_period_start,
    'current_period_end',s.current_period_end,
    'cancel_at_period_end',s.cancel_at_period_end,
    'revision',s.revision
  ) INTO v_result
  FROM public.organization_subscriptions s
  JOIN public.subscription_plans p ON p.id=s.plan_id
  WHERE s.organization_id=v_org;
  IF v_result IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Organization subscription not found';
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_subscription_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_my_subscription_v1() TO authenticated;

-- Única mutación inicial: backend/service_role con optimistic concurrency.
CREATE OR REPLACE FUNCTION private.set_organization_subscription_v1(
  p_organization_id uuid,
  p_plan_code text,
  p_status text,
  p_assignment_reason text,
  p_expected_revision bigint,
  p_period_start timestamptz DEFAULT NULL,
  p_period_end timestamptz DEFAULT NULL,
  p_cancel_at_period_end boolean DEFAULT false
)
RETURNS public.organization_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_plan uuid;
  v_row public.organization_subscriptions;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Privileged subscription writer required';
  END IF;
  SELECT id INTO v_plan FROM public.subscription_plans
  WHERE code=p_plan_code AND status='active';
  IF v_plan IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unknown active plan'; END IF;
  IF p_status NOT IN ('trialing','active','past_due','suspended','canceled') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid subscription status';
  END IF;
  IF p_assignment_reason NOT IN ('legacy_grandfathered','bootstrap_default','admin_override','billing_sync') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid assignment reason';
  END IF;
  UPDATE public.organization_subscriptions s
  SET plan_id=v_plan,status=p_status,assignment_reason=p_assignment_reason,
      current_period_start=p_period_start,current_period_end=p_period_end,
      cancel_at_period_end=COALESCE(p_cancel_at_period_end,false),
      revision=s.revision+1,updated_at=now()
  WHERE s.organization_id=p_organization_id AND s.revision=p_expected_revision
  RETURNING s.* INTO v_row;
  IF v_row.organization_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='Subscription revision conflict or organization not found';
  END IF;
  RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)
  TO service_role;

COMMIT;
