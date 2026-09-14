-- Fase 4.5 SaaS: roles y permisos configurables por organización.
BEGIN;

CREATE TABLE public.permissions (
  code text PRIMARY KEY,
  category text NOT NULL,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT permissions_code_format CHECK(code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  CONSTRAINT permissions_name_not_blank CHECK(btrim(name)<>''),
  CONSTRAINT permissions_category_not_blank CHECK(btrim(category)<>'')
);

INSERT INTO public.permissions(code,category,name) VALUES
 ('products.create','products','Crear productos'),
 ('products.update','products','Editar productos'),
 ('products.change_price','products','Cambiar precios'),
 ('inventory.receive','inventory','Recibir inventario'),
 ('inventory.adjust','inventory','Ajustar inventario'),
 ('sales.create','sales','Registrar ventas'),
 ('sales.discount','sales','Aplicar descuentos'),
 ('purchases.manage','purchases','Gestionar compras'),
 ('reports.view_profit','reports','Ver utilidad'),
 ('business.configure','business','Configurar empresa')
ON CONFLICT(code) DO NOTHING;

CREATE TABLE public.roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  is_system boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT roles_organization_fkey FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE,
  CONSTRAINT roles_organization_id_key UNIQUE(organization_id,id),
  CONSTRAINT roles_code_format CHECK(code=lower(btrim(code)) AND code ~ '^[a-z][a-z0-9_-]{0,31}$'),
  CONSTRAINT roles_name_not_blank CHECK(btrim(name)<>''),
  CONSTRAINT roles_status_valid CHECK(status IN ('active','inactive'))
);
CREATE UNIQUE INDEX roles_organization_code_key ON public.roles(organization_id,code);
CREATE INDEX roles_organization_status_idx ON public.roles(organization_id,status);

CREATE TABLE public.role_permissions (
  organization_id uuid NOT NULL,
  role_id uuid NOT NULL,
  permission_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  PRIMARY KEY(organization_id,role_id,permission_code),
  CONSTRAINT role_permissions_role_fkey FOREIGN KEY(organization_id,role_id) REFERENCES public.roles(organization_id,id) ON DELETE CASCADE,
  CONSTRAINT role_permissions_permission_fkey FOREIGN KEY(permission_code) REFERENCES public.permissions(code) ON DELETE RESTRICT
);

CREATE TABLE public.employee_roles (
  organization_id uuid NOT NULL,
  employee_id bigint NOT NULL,
  role_id uuid NOT NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  assigned_by uuid,
  PRIMARY KEY(organization_id,employee_id,role_id),
  CONSTRAINT employee_roles_employee_fkey FOREIGN KEY(organization_id,employee_id) REFERENCES public.empleados(organization_id,id) ON DELETE CASCADE,
  CONSTRAINT employee_roles_role_fkey FOREIGN KEY(organization_id,role_id) REFERENCES public.roles(organization_id,id) ON DELETE CASCADE
);
CREATE INDEX employee_roles_role_idx ON public.employee_roles(organization_id,role_id,employee_id);

-- Roles base por tenant: admin no editable en permisos; operador sirve como punto de partida configurable.
INSERT INTO public.roles(organization_id,code,name,is_system,status)
SELECT o.id,'admin','Administrador',true,'active' FROM public.organizations o
ON CONFLICT(organization_id,code) DO NOTHING;
INSERT INTO public.roles(organization_id,code,name,is_system,status)
SELECT o.id,'operator','Operador',true,'active' FROM public.organizations o
ON CONFLICT(organization_id,code) DO NOTHING;

INSERT INTO public.role_permissions(organization_id,role_id,permission_code)
SELECT r.organization_id,r.id,p.code
FROM public.roles r CROSS JOIN public.permissions p
WHERE r.code='admin' AND r.status='active' AND p.is_active
ON CONFLICT DO NOTHING;

INSERT INTO public.role_permissions(organization_id,role_id,permission_code)
SELECT r.organization_id,r.id,p.code
FROM public.roles r JOIN public.permissions p ON p.code IN ('inventory.receive','sales.create','sales.discount')
WHERE r.code='operator' AND r.status='active'
ON CONFLICT DO NOTHING;

INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT e.organization_id,e.id,r.id
FROM public.empleados e
JOIN public.roles r ON r.organization_id=e.organization_id
 AND r.code=CASE WHEN lower(btrim(COALESCE(e.rol,''))) IN ('admin','administrador') THEN 'admin' ELSE 'operator' END
ON CONFLICT DO NOTHING;

-- Nuevos tenants reciben roles del sistema automáticamente.
CREATE OR REPLACE FUNCTION public._organization_create_system_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_admin uuid; v_operator uuid;
BEGIN
  INSERT INTO public.roles(organization_id,code,name,is_system,status)
  VALUES(NEW.id,'admin','Administrador',true,'active') RETURNING id INTO v_admin;
  INSERT INTO public.roles(organization_id,code,name,is_system,status)
  VALUES(NEW.id,'operator','Operador',true,'active') RETURNING id INTO v_operator;
  INSERT INTO public.role_permissions(organization_id,role_id,permission_code)
  SELECT NEW.id,v_admin,p.code FROM public.permissions p WHERE p.is_active;
  INSERT INTO public.role_permissions(organization_id,role_id,permission_code)
  SELECT NEW.id,v_operator,p.code FROM public.permissions p
  WHERE p.code IN ('inventory.receive','sales.create','sales.discount') AND p.is_active;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._organization_create_system_roles() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_organization_create_system_roles
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION public._organization_create_system_roles();

-- Nuevos empleados heredan rol legacy sólo como bootstrap de compatibilidad.
CREATE OR REPLACE FUNCTION private.assign_default_employee_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_role uuid;
BEGIN
  SELECT r.id INTO v_role FROM public.roles r
  WHERE r.organization_id=NEW.organization_id
    AND r.code=CASE WHEN lower(btrim(COALESCE(NEW.rol,''))) IN ('admin','administrador') THEN 'admin' ELSE 'operator' END
    AND r.status='active';
  IF v_role IS NOT NULL THEN
    INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
    VALUES(NEW.organization_id,NEW.id,v_role) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.assign_default_employee_role() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER empleados_assign_default_role
AFTER INSERT ON public.empleados
FOR EACH ROW EXECUTE FUNCTION private.assign_default_employee_role();

-- F2.3 (08025000) ya convirtió employee_permission_overrides a ownership tenant:
-- organization_id NOT NULL, PK (organization_id,employee_id,permission_code),
-- FK compuesta al empleado y RLS. F4.5 conserva esa base y sustituye únicamente
-- el catálogo CHECK legacy por la FK al catálogo configurable de permissions.
UPDATE public.employee_permission_overrides o
SET organization_id=e.organization_id
FROM public.empleados e
WHERE o.organization_id IS NULL AND o.employee_id=e.id;
DO $override_guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.employee_permission_overrides WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped permission override remains';
  END IF;
END;
$override_guard$;
ALTER TABLE public.employee_permission_overrides
  ALTER COLUMN organization_id SET NOT NULL,
  DROP CONSTRAINT IF EXISTS employee_permission_code_known,
  DROP CONSTRAINT IF EXISTS employee_permission_overrides_permission_fkey,
  ADD CONSTRAINT employee_permission_overrides_permission_fkey FOREIGN KEY(permission_code) REFERENCES public.permissions(code) ON DELETE CASCADE;

ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_roles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.permissions,public.roles,public.role_permissions,public.employee_roles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.permissions,public.roles,public.role_permissions,public.employee_roles TO authenticated;

CREATE POLICY permissions_authenticated_read ON public.permissions FOR SELECT TO authenticated USING(is_active);
CREATE POLICY roles_tenant_read ON public.roles FOR SELECT TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));
CREATE POLICY role_permissions_tenant_read ON public.role_permissions FOR SELECT TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));
CREATE POLICY employee_roles_tenant_read ON public.employee_roles FOR SELECT TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));

-- Retira tanto la policy legacy pre-SaaS como la policy transitoria de F2.3 para
-- que sólo quede el contrato F4.5. 08041100 la vuelve a crear con scope explícito.
DROP POLICY IF EXISTS employee_permission_read ON public.employee_permission_overrides;
DROP POLICY IF EXISTS employee_permission_overrides_tenant_select ON public.employee_permission_overrides;
DROP POLICY IF EXISTS employee_permission_tenant_read ON public.employee_permission_overrides;
CREATE POLICY employee_permission_tenant_read ON public.employee_permission_overrides FOR SELECT TO authenticated
USING(
  private.row_belongs_to_current_organization(organization_id)
  AND (
    private.has_permission('tenant.admin')
    OR employee_id=(SELECT e.id FROM public.empleados e WHERE e.organization_id=organization_id AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid()) LIMIT 1)
  )
);

-- -----------------------------------------------------------------------------
-- Autorización de dominio: misma firma, implementación configurable.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_tiene_permiso(p_permission_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
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
  WHERE e.organization_id=v_org AND e.employment_status='active'
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
$$;

CREATE OR REPLACE FUNCTION public.get_my_effective_permissions_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_employee_id bigint; v_permissions jsonb;
BEGIN
  SELECT e.id INTO v_employee_id FROM public.empleados e
  WHERE e.organization_id=v_org AND e.employment_status='active'
    AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
  ORDER BY CASE WHEN e.app_user_id=auth.uid() THEN 0 ELSE 1 END,e.id LIMIT 1;
  IF v_employee_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Employee identity required'; END IF;
  SELECT COALESCE(jsonb_agg(p.code ORDER BY p.code),'[]'::jsonb) INTO v_permissions
  FROM public.permissions p WHERE p.is_active AND public.app_tiene_permiso(p.code);
  RETURN jsonb_build_object('supported',true,'employee_id',v_employee_id,'permissions',v_permissions);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_employee_permission_settings_v1(p_employee_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_permissions jsonb; v_roles jsonb;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.empleados e WHERE e.organization_id=v_org AND e.id=p_employee_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee not available in current organization';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'name',r.name) ORDER BY r.name),'[]'::jsonb)
  INTO v_roles FROM public.employee_roles er JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
  WHERE er.organization_id=v_org AND er.employee_id=p_employee_id;
  SELECT COALESCE(jsonb_object_agg(p.code,jsonb_build_object(
    'base_allowed',EXISTS(SELECT 1 FROM public.employee_roles er JOIN public.role_permissions rp ON rp.organization_id=er.organization_id AND rp.role_id=er.role_id WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND rp.permission_code=p.code),
    'override',(SELECT o.allowed FROM public.employee_permission_overrides o WHERE o.organization_id=v_org AND o.employee_id=p_employee_id AND o.permission_code=p.code)
  )),'{}'::jsonb) INTO v_permissions FROM public.permissions p WHERE p.is_active;
  RETURN jsonb_build_object('employee_id',p_employee_id,'roles',v_roles,'permissions',v_permissions);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_employee_permission_overrides_v1(p_employee_id bigint,p_overrides jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_key text; v_value jsonb;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required'; END IF;
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides)<>'object' THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Overrides must be an object'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.empleados e WHERE e.organization_id=v_org AND e.id=p_employee_id) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee not available in current organization'; END IF;
  IF EXISTS(SELECT 1 FROM public.employee_roles er JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND r.code='admin') THEN
    DELETE FROM public.employee_permission_overrides WHERE organization_id=v_org AND employee_id=p_employee_id;
    RETURN public.get_employee_permission_settings_v1(p_employee_id);
  END IF;
  FOR v_key,v_value IN SELECT key,value FROM jsonb_each(p_overrides) LOOP
    IF NOT EXISTS(SELECT 1 FROM public.permissions p WHERE p.code=v_key AND p.is_active) THEN RAISE EXCEPTION 'Unknown permission: %',v_key USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(v_value)<>'boolean' THEN RAISE EXCEPTION 'Permission % must be boolean',v_key USING ERRCODE='22023'; END IF;
    INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_code,allowed,updated_at,updated_by)
    VALUES(v_org,p_employee_id,v_key,(v_value#>>'{}')::boolean,now(),auth.uid())
    ON CONFLICT(organization_id,employee_id,permission_code) DO UPDATE SET allowed=excluded.allowed,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
  END LOOP;
  RETURN public.get_employee_permission_settings_v1(p_employee_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- Administración de roles.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_role_v1(p_code text,p_name text,p_permissions text[] DEFAULT ARRAY[]::text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_role public.roles; v_permission text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required'; END IF;
  INSERT INTO public.roles(organization_id,code,name,is_system,status) VALUES(v_org,lower(btrim(p_code)),btrim(p_name),false,'active') RETURNING * INTO v_role;
  FOREACH v_permission IN ARRAY COALESCE(p_permissions,ARRAY[]::text[]) LOOP
    IF NOT EXISTS(SELECT 1 FROM public.permissions p WHERE p.code=v_permission AND p.is_active) THEN RAISE EXCEPTION 'Unknown permission: %',v_permission USING ERRCODE='22023'; END IF;
    INSERT INTO public.role_permissions(organization_id,role_id,permission_code,created_by) VALUES(v_org,v_role.id,v_permission,auth.uid());
  END LOOP;
  RETURN to_jsonb(v_role);
END; $$;

CREATE OR REPLACE FUNCTION public.set_role_permissions_v1(p_role_id uuid,p_permissions text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_role public.roles; v_permission text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required'; END IF;
  SELECT * INTO v_role FROM public.roles WHERE organization_id=v_org AND id=p_role_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Role not available in current organization'; END IF;
  IF v_role.code='admin' THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='System admin role permissions are immutable'; END IF;
  DELETE FROM public.role_permissions WHERE organization_id=v_org AND role_id=p_role_id;
  FOREACH v_permission IN ARRAY COALESCE(p_permissions,ARRAY[]::text[]) LOOP
    IF NOT EXISTS(SELECT 1 FROM public.permissions p WHERE p.code=v_permission AND p.is_active) THEN RAISE EXCEPTION 'Unknown permission: %',v_permission USING ERRCODE='22023'; END IF;
    INSERT INTO public.role_permissions(organization_id,role_id,permission_code,created_by) VALUES(v_org,p_role_id,v_permission,auth.uid());
  END LOOP;
  RETURN jsonb_build_object('role_id',p_role_id,'permissions',to_jsonb(COALESCE(p_permissions,ARRAY[]::text[])));
END; $$;

CREATE OR REPLACE FUNCTION public.set_employee_roles_v1(p_employee_id bigint,p_role_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_role_id uuid;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.empleados e WHERE e.organization_id=v_org AND e.id=p_employee_id) THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee not available in current organization'; END IF;
  IF COALESCE(array_length(p_role_ids,1),0)=0 THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee must keep at least one role'; END IF;
  FOREACH v_role_id IN ARRAY p_role_ids LOOP
    IF NOT EXISTS(SELECT 1 FROM public.roles r WHERE r.organization_id=v_org AND r.id=v_role_id AND r.status='active') THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Role not available in current organization'; END IF;
  END LOOP;
  DELETE FROM public.employee_roles WHERE organization_id=v_org AND employee_id=p_employee_id;
  FOREACH v_role_id IN ARRAY p_role_ids LOOP
    INSERT INTO public.employee_roles(organization_id,employee_id,role_id,assigned_by) VALUES(v_org,p_employee_id,v_role_id,auth.uid());
  END LOOP;
  RETURN public.get_employee_permission_settings_v1(p_employee_id);
END; $$;

REVOKE ALL ON FUNCTION public.create_role_v1(text,text,text[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.set_role_permissions_v1(uuid,text[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.set_employee_roles_v1(bigint,uuid[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.app_tiene_permiso(text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_my_effective_permissions_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_employee_permission_settings_v1(bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_role_v1(text,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_role_permissions_v1(uuid,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_roles_v1(bigint,uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_tiene_permiso(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_effective_permissions_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_employee_permission_settings_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) TO authenticated;

COMMIT;