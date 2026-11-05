-- 2D-G: privileged legacy role lookup must never read a different tenant.
-- app_users is still one-org-per-user: this is a BOLA containment fix, NOT
-- a multi-membership migration. Definer is retained for employee RLS access.
-- It cannot infer active organization from caller-supplied tenant IDs.
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=''
AS $body$
 SELECT e.rol
 FROM public.empleados e
 JOIN public.app_users au
   ON au.organization_id=e.organization_id
  AND au.user_id=auth.uid()
 JOIN public.organizations o
   ON o.id=e.organization_id
 WHERE e.organization_id=private.current_organization_id()
   AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
   AND au.status='active'
   AND o.status='active'
   AND e.employment_status='active'
   AND e.activo IS TRUE
   AND e.rol IN ('admin','operador')
 ORDER BY CASE WHEN e.app_user_id=auth.uid() THEN 0 ELSE 1 END,e.id
 LIMIT 1;
$body$;
-- Explicit grants; public/anon may never invoke the definer.
REVOKE ALL ON FUNCTION public.get_user_role() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated;

-- 2D-G: _gre_empleado_activo denies logically inactive employees even when one flag is stale.
CREATE OR REPLACE FUNCTION public._gre_empleado_activo()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      AND e.employment_status='active'
  );
$function$;

-- 2D-G: app_tiene_permiso denies logically inactive employees even when one flag is stale.
CREATE OR REPLACE FUNCTION public.app_tiene_permiso(p_permission_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.current_organization_id();
  v_employee_id bigint;
  v_override boolean;
  v_is_admin boolean:=false;
  v_allowed boolean:=false;
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL THEN RETURN false; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.permissions p WHERE p.code=p_permission_code AND p.is_active) THEN RETURN false; END IF;

  SELECT e.id INTO v_employee_id FROM public.empleados e
  WHERE e.organization_id=v_org AND e.employment_status='active' AND COALESCE(e.activo,false)=true
    AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
  ORDER BY CASE WHEN e.app_user_id=auth.uid() THEN 0 ELSE 1 END,e.id LIMIT 1;
  IF v_employee_id IS NULL THEN RETURN false; END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.employee_roles er
    JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
    WHERE er.organization_id=v_org AND er.employee_id=v_employee_id
      AND r.code='admin' AND r.status='active'
  ) INTO v_is_admin;
  IF v_is_admin THEN RETURN true; END IF;

  SELECT o.allowed INTO v_override FROM public.employee_permission_overrides o
  WHERE o.organization_id=v_org AND o.employee_id=v_employee_id AND o.permission_code=p_permission_code;
  IF FOUND THEN RETURN v_override; END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.employee_roles er
    JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id AND r.status='active'
    JOIN public.role_permissions rp ON rp.organization_id=r.organization_id AND rp.role_id=r.id
    WHERE er.organization_id=v_org AND er.employee_id=v_employee_id AND rp.permission_code=p_permission_code
  ) INTO v_allowed;
  RETURN v_allowed;
END;
$function$;

-- 2D-G: get_my_effective_permissions_v1 denies logically inactive employees even when one flag is stale.
CREATE OR REPLACE FUNCTION public.get_my_effective_permissions_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_employee_id bigint;
  v_primary_role text;
  v_permissions jsonb;
BEGIN
  SELECT e.id INTO v_employee_id
  FROM public.empleados e
  WHERE e.organization_id=v_org AND e.employment_status='active' AND COALESCE(e.activo,false)=true
    AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
  ORDER BY CASE WHEN e.app_user_id=auth.uid() THEN 0 ELSE 1 END,e.id
  LIMIT 1;
  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Employee identity required';
  END IF;

  SELECT r.code INTO v_primary_role
  FROM public.employee_roles er
  JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
  WHERE er.organization_id=v_org AND er.employee_id=v_employee_id AND r.status='active'
  ORDER BY CASE WHEN r.code='admin' THEN 0 WHEN r.code='operator' THEN 1 ELSE 2 END,r.name,r.id
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(p.code ORDER BY p.code),'[]'::jsonb)
  INTO v_permissions
  FROM public.permissions p
  WHERE p.is_active AND public.app_tiene_permiso(p.code);

  RETURN jsonb_build_object(
    'supported',true,
    'employee_id',v_employee_id,
    'role',COALESCE(v_primary_role,'operator'),
    'permissions',v_permissions
  );
END;
$function$;

-- 2D-G: eliminate cross-tenant data reads in privileged obtener_tendencia_movimientos.
CREATE OR REPLACE FUNCTION public.obtener_tendencia_movimientos(p_tipo text, p_inicio timestamp with time zone, p_fin timestamp with time zone)
 RETURNS TABLE(fecha_agrupada date, total numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  RETURN QUERY
  SELECT
    DATE(m.fecha AT TIME ZONE 'America/Lima') AS fecha_agrupada,
    SUM(m.monto) AS total
  FROM public.movimientos AS m
  WHERE m.organization_id=private.require_current_organization_id()
    AND m.tipo = p_tipo
    AND m.fecha >= p_inicio
    AND m.fecha <= p_fin
  GROUP BY DATE(m.fecha AT TIME ZONE 'America/Lima')
  ORDER BY fecha_agrupada ASC;
END;
$function$;

-- 2D-G: eliminate cross-tenant data reads in privileged resolve_sale_price_v1.
CREATE OR REPLACE FUNCTION public.resolve_sale_price_v1(p_product_id bigint, p_presentation_code text, p_quantity numeric, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_base numeric;
  v_rule public.sale_price_rules%ROWTYPE;
  v_price numeric;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE='42501';
  END IF;
  IF p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN ('NaN','Infinity','-Infinity') THEN
    RAISE EXCEPTION 'Cantidad inválida';
  END IF;
  -- 2D-G: privileged product pricing must not reveal another tenant's catalog.
  PERFORM private.assert_product_in_current_organization(p_product_id);
  v_base := public._catalog_commercial_price_v1(p_product_id,p_presentation_code);

  SELECT * INTO v_rule
  FROM public.sale_price_rules r
  WHERE r.product_id=p_product_id
    AND r.active
    AND (r.presentation_code IS NULL OR r.presentation_code=lower(trim(p_presentation_code)))
    AND p_quantity>=r.min_quantity
    AND (r.starts_at IS NULL OR p_at>=r.starts_at)
    AND (r.ends_at IS NULL OR p_at<r.ends_at)
  ORDER BY r.priority DESC, r.min_quantity DESC, r.id DESC
  LIMIT 1;

  IF FOUND THEN
    v_price := CASE
      WHEN v_rule.fixed_price IS NOT NULL THEN v_rule.fixed_price
      ELSE v_base * (1 - v_rule.discount_percent/100)
    END;
  ELSE
    v_price := v_base;
  END IF;
  v_price := round(greatest(v_price,0),4);

  RETURN jsonb_build_object(
    'product_id',p_product_id,
    'presentation_code',lower(trim(p_presentation_code)),
    'quantity',p_quantity,
    'catalog_price',v_base,
    'price',v_price,
    'rule_id',CASE WHEN FOUND THEN v_rule.id ELSE NULL END,
    'rule_name',CASE WHEN FOUND THEN v_rule.name ELSE NULL END
  );
END;
$function$;
