-- F8.1 hardening: el dueño creado por el alta autoservicio también necesita
-- una identidad laboral activa para usar los permisos operativos configurables.
BEGIN;

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
  v_owner_email text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;

  v_org:=public.bootstrap_organization_v1(
    p_display_name,p_country_code,p_currency_code,p_timezone,p_legal_name
  );

  SELECT lower(NULLIF(btrim(u.email),''))
  INTO v_owner_email
  FROM auth.users u
  WHERE u.id=v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE='28000',
      MESSAGE='Authenticated user no longer exists';
  END IF;

  -- app_users, la sucursal principal y los roles del sistema ya fueron creados
  -- por el bootstrap y sus triggers. La ficha enlazada recibe el rol admin por
  -- empleados_assign_default_role, sin confiar organization_id del cliente.
  INSERT INTO public.empleados(
    organization_id,
    app_user_id,
    auth_id,
    nombre,
    email,
    rol,
    activo,
    creado_por
  ) VALUES (
    v_org,
    v_user,
    v_user,
    COALESCE(
      NULLIF(split_part(COALESCE(v_owner_email,''),'@',1),''),
      btrim(p_display_name) || ' admin'
    ),
    v_owner_email,
    'admin',
    true,
    v_user
  );

  SELECT s.revision INTO v_revision
  FROM public.organization_subscriptions s
  WHERE s.organization_id=v_org
  FOR UPDATE;

  IF v_revision IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='Bootstrap subscription was not created';
  END IF;

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

REVOKE ALL ON FUNCTION public.create_my_organization_v1(text,text,text,text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_my_organization_v1(text,text,text,text,text)
  TO authenticated;

COMMENT ON FUNCTION public.create_my_organization_v1(text,text,text,text,text) IS
  'Alta SaaS autoservicio atómica con membership y ficha laboral admin enlazadas server-side.';

COMMIT;
