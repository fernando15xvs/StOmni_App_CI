-- Fase 3.7 SaaS: compatibilidad de identidad para motores fiscales legacy.
-- app_users/base_role es la autoridad de acceso; empleados sólo confirma vínculo
-- laboral activo. auth_id queda como fallback transitorio de filas históricas.
BEGIN;

CREATE OR REPLACE FUNCTION public._gre_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_users au
    JOIN public.empleados e
      ON e.organization_id=au.organization_id
     AND (e.app_user_id=au.user_id OR e.auth_id=au.user_id)
    JOIN public.organizations o ON o.id=au.organization_id
    WHERE au.user_id=auth.uid()
      AND au.organization_id=private.require_current_organization_id()
      AND au.status='active'
      AND au.base_role IN ('admin','operador')
      AND o.status='active'
      AND COALESCE(e.activo,false)=true
  );
$$;

-- Nota de crédito: sustituir el guard laboral/rol legacy por permiso canónico
-- y vínculo de empleado activo del mismo tenant.
DO $patch_nc_identity$
DECLARE
  v_sig regprocedure := 'public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'IF NOT EXISTS (\n    SELECT 1\n    FROM public.empleados AS e\n    WHERE e.auth_id = auth.uid()\n      AND COALESCE(e.activo, false) = true\n      AND LOWER(COALESCE(e.rol, '''')) IN (''admin'', ''operador'')\n  ) THEN';
  v_new:=E'IF NOT private.has_permission(''tenant.write'') OR NOT EXISTS (\n    SELECT 1\n    FROM public.empleados AS e\n    WHERE e.organization_id = private.require_current_organization_id()\n      AND (e.app_user_id = auth.uid() OR e.auth_id = auth.uid())\n      AND COALESCE(e.activo, false) = true\n  ) THEN';
  IF strpos(v_def,v_old)=0 THEN
    RAISE EXCEPTION 'F3.7 identity patch mismatch: credit note actor';
  END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_nc_identity$;

-- Baja tributaria: sólo tenant.admin canónico + empleado activo vinculado.
-- El snapshot histórico conocido existe en dos formas equivalentes: el rol admin
-- puede aparecer como IN ('admin') en una sola línea o expandido en varias. Se
-- aceptan EXCLUSIVAMENTE esas dos formas verificadas; cualquier tercera variante
-- sigue fallando de manera cerrada para no aplicar un parche ambiguo.
DO $patch_baja_identity$
DECLARE
  v_sig regprocedure := 'public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure;
  v_def text;
  v_old_multiline text;
  v_old_compact text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_def:=replace(replace(v_def,E'\r\n',E'\n'),E'\r',E'\n');

  v_old_multiline:=E'IF NOT EXISTS (\n    SELECT 1 FROM public.empleados e\n    WHERE e.auth_id = auth.uid()\n      AND COALESCE(e.activo, false) = true\n      AND lower(COALESCE(e.rol, '''')) IN (\n        ''admin''\n      )\n  ) THEN';
  v_old_compact:=E'IF NOT EXISTS (\n    SELECT 1 FROM public.empleados e\n    WHERE e.auth_id = auth.uid()\n      AND COALESCE(e.activo, false) = true\n      AND lower(COALESCE(e.rol, '''')) IN (''admin'')\n  ) THEN';
  v_new:=E'IF NOT private.has_permission(''tenant.admin'') OR NOT EXISTS (\n    SELECT 1 FROM public.empleados e\n    WHERE e.organization_id = private.require_current_organization_id()\n      AND (e.app_user_id = auth.uid() OR e.auth_id = auth.uid())\n      AND COALESCE(e.activo, false) = true\n  ) THEN';

  IF strpos(v_def,v_old_multiline)>0 THEN
    v_def:=replace(v_def,v_old_multiline,v_new);
  ELSIF strpos(v_def,v_old_compact)>0 THEN
    v_def:=replace(v_def,v_old_compact,v_new);
  ELSE
    RAISE EXCEPTION 'F3.7 identity patch mismatch: tax cancellation actor';
  END IF;

  EXECUTE v_def;
END;
$patch_baja_identity$;

-- Claims internos llamados por Edge: el Edge ya validó base_role desde app_users.
-- PostgreSQL exige además que p_usuario_id tenga un empleado activo del tenant.
DO $patch_service_identity$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_old text := 'AND e.auth_id = p_usuario_id';
  v_new text := 'AND (e.app_user_id = p_usuario_id OR e.auth_id = p_usuario_id)';
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)'::regprocedure,
    'public.nota_credito_claim(uuid,uuid,text,boolean,boolean)'::regprocedure,
    'public.gre_claim_v2(uuid,uuid,text,boolean,boolean)'::regprocedure,
    'public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)'::regprocedure
  ] LOOP
    SELECT pg_get_functiondef(v_sig) INTO v_def;
    IF strpos(v_def,v_old)=0 THEN
      RAISE EXCEPTION 'F3.7 identity patch mismatch: %',v_sig;
    END IF;
    v_def:=replace(v_def,v_old,v_new);
    EXECUTE v_def;
  END LOOP;
END;
$patch_service_identity$;

-- Mantener helpers/motores internos fuera de la superficie cliente.
REVOKE ALL ON FUNCTION public._gre_empleado_activo() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC,anon,authenticated;

COMMIT;
