-- F6.1 hardening: actor snapshot compatible con transición y entity id semántico.
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
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_session_org uuid := private.current_organization_id();
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
  IF v_user IS NOT NULL AND v_session_org IS DISTINCT FROM p_organization_id THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant audit event is not allowed';
  END IF;
  IF p_action IS NULL OR p_entity_type IS NULL OR p_source_table IS NULL OR p_source_operation IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Audit event fields are required';
  END IF;
  IF jsonb_typeof(v_metadata)<>'object' OR pg_column_size(v_metadata)>32768 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Audit metadata must be a JSON object <= 32 KiB';
  END IF;

  IF v_user IS NOT NULL THEN
    SELECT e.id, nullif(btrim(e.nombre),'')
      INTO v_employee_id, v_employee_label
    FROM public.empleados e
    WHERE e.organization_id=p_organization_id
      AND (e.app_user_id=v_user OR e.auth_id=v_user)
    ORDER BY CASE WHEN e.app_user_id=v_user THEN 0 ELSE 1 END,e.id
    LIMIT 1;
    v_role:=private.current_base_role();
  ELSE
    -- SECURITY DEFINER cambia current_user al owner de la función. No lo usamos
    -- como identidad del actor: sin auth.uid() el evento se marca explícitamente
    -- como proceso interno y conserva la entidad/tenant que originó el trigger.
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
REVOKE ALL ON FUNCTION private.write_audit_log(uuid,text,text,text,text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.audit_allowlisted_change_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  v_new jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE '{}'::jsonb END;
  v_row jsonb := CASE WHEN TG_OP='DELETE' THEN v_old ELSE v_new END;
  v_fields text[] := string_to_array(coalesce(TG_ARGV[2],''),',');
  v_before jsonb;
  v_after jsonb;
  v_metadata jsonb;
  v_org uuid;
  v_entity_id text;
  v_request_id uuid;
BEGIN
  v_org:=nullif(v_row->>'organization_id','')::uuid;
  IF v_org IS NULL THEN v_org:=private.require_current_organization_id(); END IF;
  v_entity_id:=coalesce(
    nullif(v_row->>'id',''),
    nullif(v_row->>'venta_id_original',''),
    nullif(v_row->>'role_id',''),
    nullif(v_row->>'employee_id',''),
    nullif(v_row->>'product_id',''),
    nullif(v_row->>'producto_id',''),
    nullif(v_row->>'request_id','')
  );
  BEGIN
    v_request_id:=nullif(v_row->>'request_id','')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_request_id:=NULL;
  END;

  IF TG_OP='UPDATE' THEN
    v_before:=private.audit_pick_fields(v_old,v_fields);
    v_after:=private.audit_pick_fields(v_new,v_fields);
    IF v_before=v_after THEN RETURN NEW; END IF;
    v_metadata:=jsonb_build_object('before',v_before,'after',v_after);
  ELSIF TG_OP='INSERT' THEN
    v_metadata:=jsonb_build_object('values',private.audit_pick_fields(v_new,v_fields));
  ELSE
    v_metadata:=jsonb_build_object('values',private.audit_pick_fields(v_old,v_fields));
  END IF;

  PERFORM private.write_audit_log(
    v_org,TG_ARGV[0],TG_ARGV[1],v_entity_id,TG_TABLE_NAME,TG_OP,v_request_id,v_metadata
  );
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE ALL ON FUNCTION private.audit_allowlisted_change_trigger() FROM PUBLIC,anon,authenticated;

COMMIT;
