-- Fase 8.1: alta autoservicio segura de empresa.
-- El bootstrap técnico F1.4 queda detrás de una RPC de onboarding que evita
-- que nuevos tenants hereden el plan Enterprise de transición.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_organization_signup_state_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_user uuid:=auth.uid();
  v_membership public.app_users;
  v_org public.organizations;
  v_has_legacy_identity boolean:=false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;

  SELECT * INTO v_membership
  FROM public.app_users au
  WHERE au.user_id=v_user;

  IF FOUND THEN
    SELECT * INTO v_org FROM public.organizations o WHERE o.id=v_membership.organization_id;
    RETURN jsonb_build_object(
      'state','attached',
      'eligible',false,
      'organization_id',v_membership.organization_id,
      'organization_status',v_org.status,
      'membership_status',v_membership.status,
      'display_name',v_org.display_name
    );
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id=v_user OR e.app_user_id=v_user
  ) INTO v_has_legacy_identity;

  IF v_has_legacy_identity THEN
    RETURN jsonb_build_object(
      'state','legacy_identity_requires_migration',
      'eligible',false,
      'organization_id',NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'state','eligible',
    'eligible',true,
    'organization_id',NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_my_organization_v1(
  p_display_name text,
  p_country_code text,
  p_currency_code text,
  p_timezone text,
  p_legal_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_user uuid:=auth.uid();
  v_org uuid;
  v_revision bigint;
  v_subscription public.organization_subscriptions;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;

  -- bootstrap_organization_v1 mantiene serialización, validación de identidad,
  -- atomicidad y creación de configuración/capabilities/sucursal/caja/defaults.
  v_org:=public.bootstrap_organization_v1(
    p_display_name,p_country_code,p_currency_code,p_timezone,p_legal_name
  );

  SELECT s.revision INTO v_revision
  FROM public.organization_subscriptions s
  WHERE s.organization_id=v_org
  FOR UPDATE;

  IF v_revision IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Bootstrap subscription was not created';
  END IF;

  -- F7.2 usa Enterprise sólo como rollout fail-safe para tenants preexistentes.
  -- Un tenant autoservicio nuevo entra por la identidad de plan Starter.
  v_subscription:=private.set_organization_subscription_v1(
    v_org,'starter','active','bootstrap_default',v_revision,NULL,NULL,false
  );

  RETURN jsonb_build_object(
    'organization_id',v_org,
    'display_name',btrim(p_display_name),
    'country_code',upper(btrim(p_country_code)),
    'currency_code',upper(btrim(p_currency_code)),
    'timezone',btrim(p_timezone),
    'membership_role','admin',
    'subscription',jsonb_build_object(
      'plan_code','starter',
      'status',v_subscription.status,
      'revision',v_subscription.revision
    )
  );
END;
$$;

-- El bootstrap técnico deja de ser un entrypoint de cliente para impedir que
-- se salte el contrato F8.1 y conserve Enterprise bootstrap_default.
REVOKE EXECUTE ON FUNCTION public.bootstrap_organization_v1(text,text,text,text,text)
  FROM authenticated;
REVOKE ALL ON FUNCTION public.get_organization_signup_state_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.create_my_organization_v1(text,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_organization_signup_state_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_my_organization_v1(text,text,text,text,text) TO authenticated;

COMMENT ON FUNCTION public.get_organization_signup_state_v1() IS
  'Determina si auth.uid() puede crear una empresa sin depender de membership previa ni exponer otros tenants.';
COMMENT ON FUNCTION public.create_my_organization_v1(text,text,text,text,text) IS
  'Alta SaaS autoservicio atómica. Reutiliza bootstrap F1.4 y asigna Starter a tenants nuevos; no acepta organization_id ni plan_code del cliente.';

COMMIT;
