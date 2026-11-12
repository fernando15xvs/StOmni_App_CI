-- 2D-I2: scope audit actor organization and role to the same validated membership.
-- No second membership is enabled. Bootstrap GUC remains limited to the existing
-- transactional onboarding flow; service-only audit without a JWT stays system.
CREATE OR REPLACE FUNCTION private.write_audit_log(p_organization_id uuid, p_action text, p_entity_type text, p_entity_id text, p_source_table text, p_source_operation text, p_request_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    -- 2D-I2 readiness: role and tenant must follow the selected membership.
    -- The former lookup by user_id alone became ambiguous under multi-org.
    SELECT private.current_organization_id(), private.current_base_role()
      INTO v_session_org, v_role;

    -- Temporary pre-employee bootstrap only; never permit a revoked worker.
    IF v_session_org IS NOT NULL AND v_role IS NULL THEN
      IF EXISTS (
        SELECT 1 FROM public.app_users au
        WHERE au.user_id=v_user
          AND au.organization_id=v_session_org
          AND au.status='active' AND au.base_role='admin'
      ) AND NOT EXISTS (
        SELECT 1 FROM public.empleados e
        WHERE e.auth_id=v_user OR e.app_user_id=v_user
      ) THEN
        v_role:='admin';
      ELSE
        RAISE EXCEPTION USING ERRCODE='42501',
          MESSAGE='Active selected employee required for audit attribution';
      END IF;
    END IF;

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
$function$
;
