-- 2D-H: prevent inactive employees from inheriting tenant API permissions.
-- Before this migration current_base_role ignored employment status, while has_permission
-- returned NULL for a missing role; PL/pgSQL "IF NOT NULL" does not reject access.
-- Both helpers now fail closed. Keep existing signatures and grants unchanged.
CREATE OR REPLACE FUNCTION private.current_base_role()
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT au.base_role
  FROM public.app_users AS au
  JOIN public.organizations AS o ON o.id=au.organization_id
  WHERE au.user_id=(SELECT auth.uid())
    AND au.status='active'
    AND o.status='active'
    AND EXISTS (
      SELECT 1 FROM public.empleados AS e
      WHERE e.organization_id=au.organization_id
        AND (e.app_user_id=au.user_id OR e.auth_id=au.user_id)
        AND e.employment_status='active'
        AND e.activo IS TRUE
    )
$function$;

CREATE OR REPLACE FUNCTION private.has_permission(p_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
  SELECT COALESCE(
    CASE lower(btrim(p_permission))
      WHEN 'tenant.read' THEN (SELECT private.current_base_role()) IN ('admin','operador')
      WHEN 'tenant.write' THEN (SELECT private.current_base_role()) IN ('admin','operador')
      WHEN 'tenant.admin' THEN (SELECT private.current_base_role()) = 'admin'
      ELSE false
    END,
    false
  )
$function$;
