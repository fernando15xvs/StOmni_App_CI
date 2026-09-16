-- F8.1 hardening: el alta autoservicio crea la membership y actualiza la
-- suscripción dentro de la misma RPC. El writer de auditoría debe observar
-- esa membership recién creada sin depender del snapshot de un helper STABLE.
BEGIN;

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
    -- Consulta VOLATILE deliberada: create_my_organization_v1 inserta app_users
    -- antes de que el trigger de suscripción escriba este evento. Un helper
    -- STABLE conserva el snapshot previo a la RPC y no ve esa fila nueva.
    SELECT au.organization_id, au.base_role
      INTO v_session_org, v_role
    FROM public.app_users au
    JOIN public.organizations o ON o.id=au.organization_id
    WHERE au.user_id=v_user
      AND au.status='active'
      AND o.status='active';

    IF v_session_org IS DISTINCT FROM p_organization_id THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant audit event is not allowed';
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
