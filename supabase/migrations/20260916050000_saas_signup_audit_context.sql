-- F8.1 hardening: los AFTER INSERT de organizations crean y auditan defaults
-- antes de que bootstrap_organization_v1 pueda insertar app_users. Se expone
-- un contexto transaccional acotado al UUID server-side y al auth.uid actual.
BEGIN;

CREATE OR REPLACE FUNCTION public.bootstrap_organization_v1(
  p_display_name text,
  p_country_code text,
  p_currency_code text,
  p_timezone text,
  p_legal_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := gen_random_uuid();
  v_configuration_id integer;
  v_display_name text := nullif(btrim(p_display_name), '');
  v_country_code text := upper(nullif(btrim(p_country_code), ''));
  v_currency_code text := upper(nullif(btrim(p_currency_code), ''));
  v_timezone text := nullif(btrim(p_timezone), '');
  v_legal_name text := nullif(btrim(p_legal_name), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '28000',
      MESSAGE = 'Authentication required for organization bootstrap';
  END IF;

  IF v_display_name IS NULL OR v_country_code IS NULL
     OR v_currency_code IS NULL OR v_timezone IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'display_name, country_code, currency_code and timezone are required';
  END IF;

  PERFORM 1
  FROM auth.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = '28000',
      MESSAGE = 'Authenticated user no longer exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.app_users
    WHERE user_id = v_user_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Authenticated user already belongs to an organization';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.empleados
    WHERE auth_id = v_user_id OR app_user_id = v_user_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Legacy employee identity must be migrated before organization bootstrap';
  END IF;

  -- Sólo los triggers anidados del INSERT siguiente observan este contexto.
  -- is_local=true garantiza que nunca sobrevive a la transacción.
  PERFORM set_config(
    'stomni.bootstrap_organization_id',
    v_organization_id::text,
    true
  );
  PERFORM set_config('stomni.bootstrap_user_id', v_user_id::text, true);

  INSERT INTO public.organizations (
    id,
    legal_name,
    display_name,
    country_code,
    currency_code,
    timezone
  ) VALUES (
    v_organization_id,
    v_legal_name,
    v_display_name,
    v_country_code,
    v_currency_code,
    v_timezone
  );

  INSERT INTO public.app_users (
    user_id,
    organization_id,
    status,
    base_role
  ) VALUES (
    v_user_id,
    v_organization_id,
    'active',
    'admin'
  );

  -- Desde aquí el writer vuelve a exigir exclusivamente la membership real.
  PERFORM set_config('stomni.bootstrap_organization_id', '', true);
  PERFORM set_config('stomni.bootstrap_user_id', '', true);

  INSERT INTO public.configuracion_negocio (
    organization_id,
    razon_social,
    nombre_comercial
  ) VALUES (
    v_organization_id,
    v_legal_name,
    v_display_name
  )
  RETURNING id INTO v_configuration_id;

  INSERT INTO public.business_capabilities (
    business_id,
    organization_id
  ) VALUES (
    v_configuration_id,
    v_organization_id
  );

  RETURN v_organization_id;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_organization_v1(text,text,text,text,text)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.write_audit_log(
  p_organization_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_source_table text,
  p_source_operation text,
  p_request_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_session_org uuid;
  v_bootstrap_org uuid;
  v_bootstrap_user uuid;
  v_user uuid := auth.uid();
  v_employee_id bigint;
  v_employee_label text;
  v_role text;
  v_id bigint;
  v_metadata jsonb := coalesce(p_metadata,'{}'::jsonb);
BEGIN
  IF p_organization_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='23502', MESSAGE='Audit organization_id is required';
  END IF;
  IF p_action IS NULL OR p_entity_type IS NULL OR p_source_table IS NULL OR p_source_operation IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Audit event fields are required';
  END IF;
  IF jsonb_typeof(v_metadata)<>'object' OR pg_column_size(v_metadata)>32768 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Audit metadata must be a JSON object <= 32 KiB';
  END IF;

  IF v_user IS NOT NULL THEN
    SELECT au.organization_id, au.base_role
      INTO v_session_org, v_role
    FROM public.app_users au
    JOIN public.organizations o ON o.id=au.organization_id
    WHERE au.user_id=v_user
      AND au.status='active'
      AND o.status='active';

    IF v_session_org IS DISTINCT FROM p_organization_id THEN
      BEGIN
        v_bootstrap_org:=nullif(
          current_setting('stomni.bootstrap_organization_id',true),
          ''
        )::uuid;
        v_bootstrap_user:=nullif(
          current_setting('stomni.bootstrap_user_id',true),
          ''
        )::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        v_bootstrap_org:=NULL;
        v_bootstrap_user:=NULL;
      END;

      IF NOT (
        v_session_org IS NULL
        AND v_bootstrap_org IS NOT NULL
        AND v_bootstrap_user IS NOT NULL
        AND v_bootstrap_org=p_organization_id
        AND v_bootstrap_user=v_user
      ) THEN
        RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant audit event is not allowed';
      END IF;
      v_role:='admin';
    END IF;

    SELECT e.id, nullif(btrim(e.nombre),'')
      INTO v_employee_id, v_employee_label
    FROM public.empleados e
    WHERE e.organization_id=p_organization_id
      AND (e.app_user_id=v_user OR e.auth_id=v_user)
    ORDER BY CASE WHEN e.app_user_id=v_user THEN 0 ELSE 1 END,e.id
    LIMIT 1;
  ELSE
    v_role:='system';
    v_employee_label:='system';
  END IF;

  INSERT INTO public.audit_logs(
    organization_id,actor_user_id,actor_employee_id,actor_label,actor_role,
    action,entity_type,entity_id,source_table,source_operation,request_id,metadata
  ) VALUES (
    p_organization_id,v_user,v_employee_id,v_employee_label,v_role,
    lower(p_action),lower(p_entity_type),nullif(p_entity_id,''),
    p_source_table,upper(p_source_operation),p_request_id,v_metadata
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION private.write_audit_log(uuid,text,text,text,text,text,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;

COMMIT;
