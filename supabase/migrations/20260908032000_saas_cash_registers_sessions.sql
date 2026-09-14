-- Fase 4.3 SaaS (parte 1): cajas/puntos de operación por sucursal y sesiones tenant-aware.
BEGIN;

CREATE TABLE public.cash_registers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  is_default boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cash_registers_organization_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT cash_registers_organization_branch_fkey
    FOREIGN KEY (organization_id, branch_id)
    REFERENCES public.branches(organization_id,id) ON DELETE RESTRICT,
  CONSTRAINT cash_registers_organization_branch_id_key
    UNIQUE (organization_id, branch_id, id),
  CONSTRAINT cash_registers_code_format
    CHECK (code = upper(btrim(code)) AND code ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'),
  CONSTRAINT cash_registers_name_not_blank
    CHECK (btrim(name) <> '' AND char_length(btrim(name)) <= 120),
  CONSTRAINT cash_registers_status_valid CHECK (status IN ('active','inactive'))
);

CREATE UNIQUE INDEX cash_registers_branch_code_key
  ON public.cash_registers(organization_id, branch_id, code);
CREATE UNIQUE INDEX cash_registers_one_default_per_branch_key
  ON public.cash_registers(organization_id, branch_id) WHERE is_default;
CREATE INDEX cash_registers_branch_status_idx
  ON public.cash_registers(organization_id, branch_id, status);

ALTER TABLE public.cash_registers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.cash_registers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.cash_registers TO authenticated;

CREATE POLICY cash_registers_tenant_select ON public.cash_registers
FOR SELECT TO authenticated
USING (
  private.row_belongs_to_current_organization(organization_id)
  AND private.has_permission('tenant.read')
);

CREATE OR REPLACE FUNCTION public._cash_registers_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.code:=upper(btrim(NEW.code));
  NEW.name:=btrim(NEW.name);
  IF TG_OP='UPDATE' THEN
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
       OR NEW.branch_id IS DISTINCT FROM OLD.branch_id THEN
      RAISE EXCEPTION 'cash register identity/branch is immutable' USING ERRCODE='23514';
    END IF;
    NEW.updated_at:=clock_timestamp();
  END IF;
  IF NEW.is_default AND NEW.status<>'active' THEN
    RAISE EXCEPTION 'default cash register must be active' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._cash_registers_before_write() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_cash_registers_before_write
BEFORE INSERT OR UPDATE ON public.cash_registers
FOR EACH ROW EXECUTE FUNCTION public._cash_registers_before_write();

-- Un punto de caja por defecto para toda sucursal existente.
INSERT INTO public.cash_registers(organization_id,branch_id,code,name,is_default,status)
SELECT b.organization_id,b.id,'CASH-1','Caja principal',true,'active'
FROM public.branches b
ON CONFLICT (organization_id,branch_id,code) DO NOTHING;

CREATE OR REPLACE FUNCTION public._branch_create_default_cash_register()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.cash_registers(organization_id,branch_id,code,name,is_default,status)
  VALUES(NEW.organization_id,NEW.id,'CASH-1','Caja principal',true,'active')
  ON CONFLICT (organization_id,branch_id,code) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._branch_create_default_cash_register() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_branch_create_default_cash_register
AFTER INSERT ON public.branches
FOR EACH ROW EXECUTE FUNCTION public._branch_create_default_cash_register();

CREATE OR REPLACE FUNCTION public.create_cash_register_v1(
  p_branch_id uuid,
  p_code text,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row public.cash_registers;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can create cash registers' USING ERRCODE='42501';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.branches b WHERE b.organization_id=v_org AND b.id=p_branch_id AND b.status='active') THEN
    RAISE EXCEPTION 'Active branch not available in current organization' USING ERRCODE='P0002';
  END IF;
  INSERT INTO public.cash_registers(organization_id,branch_id,code,name,is_default,status)
  VALUES(v_org,p_branch_id,upper(btrim(p_code)),btrim(p_name),false,'active')
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_cash_register_v1(
  p_cash_register_id uuid,
  p_name text,
  p_status text DEFAULT 'active'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_status text:=lower(btrim(p_status));
  v_row public.cash_registers;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can update cash registers' USING ERRCODE='42501';
  END IF;
  IF v_status NOT IN ('active','inactive') THEN
    RAISE EXCEPTION 'Invalid cash register status' USING ERRCODE='22023';
  END IF;
  IF v_status='inactive' AND EXISTS(
    SELECT 1 FROM public.sesiones_caja s
    WHERE s.cash_register_id=p_cash_register_id AND s.estado='ABIERTA'
  ) THEN
    RAISE EXCEPTION 'Cash register has an open session' USING ERRCODE='23514';
  END IF;
  UPDATE public.cash_registers
  SET name=btrim(p_name),status=v_status
  WHERE organization_id=v_org AND id=p_cash_register_id
  RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cash register not available in current organization' USING ERRCODE='P0002'; END IF;
  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_default_cash_register_v1(p_cash_register_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row public.cash_registers;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can set default cash register' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_row FROM public.cash_registers
  WHERE organization_id=v_org AND id=p_cash_register_id AND status='active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active cash register not available in current organization' USING ERRCODE='P0002'; END IF;
  UPDATE public.cash_registers SET is_default=false
  WHERE organization_id=v_org AND branch_id=v_row.branch_id AND is_default AND id<>p_cash_register_id;
  UPDATE public.cash_registers SET is_default=true
  WHERE organization_id=v_org AND id=p_cash_register_id RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END;
$$;

REVOKE ALL ON FUNCTION public.create_cash_register_v1(uuid,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_cash_register_v1(uuid,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_default_cash_register_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_cash_register_v1(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_cash_register_v1(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_default_cash_register_v1(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Sesiones de caja tenant/branch/register-aware.
-- -----------------------------------------------------------------------------
ALTER TABLE public.sesiones_caja
  ADD COLUMN organization_id uuid,
  ADD COLUMN branch_id uuid,
  ADD COLUMN cash_register_id uuid;

DO $backfill$
DECLARE
  v_org_count integer;
  v_fallback_org uuid;
BEGIN
  UPDATE public.sesiones_caja s
  SET organization_id=e.organization_id
  FROM public.empleados e
  WHERE s.organization_id IS NULL
    AND s.usuario_id IS NOT NULL
    AND (e.app_user_id=s.usuario_id OR e.auth_id=s.usuario_id);

  SELECT count(*) INTO v_org_count FROM public.organizations;
  IF v_org_count=1 THEN SELECT id INTO v_fallback_org FROM public.organizations LIMIT 1; END IF;
  IF EXISTS(SELECT 1 FROM public.sesiones_caja WHERE organization_id IS NULL) THEN
    IF v_org_count<>1 THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Ambiguous legacy cash sessions without organization';
    END IF;
    UPDATE public.sesiones_caja SET organization_id=v_fallback_org WHERE organization_id IS NULL;
  END IF;

  UPDATE public.sesiones_caja s SET branch_id=b.id
  FROM public.branches b
  WHERE s.branch_id IS NULL AND b.organization_id=s.organization_id AND b.is_main AND b.status='active';

  UPDATE public.sesiones_caja s SET cash_register_id=c.id
  FROM public.cash_registers c
  WHERE s.cash_register_id IS NULL AND c.organization_id=s.organization_id
    AND c.branch_id=s.branch_id AND c.is_default AND c.status='active';

  IF EXISTS(SELECT 1 FROM public.sesiones_caja WHERE organization_id IS NULL OR branch_id IS NULL OR cash_register_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped cash session remains after F4.3 backfill';
  END IF;
END;
$backfill$;

ALTER TABLE public.sesiones_caja
  ALTER COLUMN organization_id SET NOT NULL,
  ALTER COLUMN branch_id SET NOT NULL,
  ALTER COLUMN cash_register_id SET NOT NULL,
  ADD CONSTRAINT sesiones_caja_organization_fkey FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT sesiones_caja_organization_branch_fkey FOREIGN KEY(organization_id,branch_id) REFERENCES public.branches(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT sesiones_caja_organization_register_fkey FOREIGN KEY(organization_id,branch_id,cash_register_id) REFERENCES public.cash_registers(organization_id,branch_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT sesiones_caja_organization_register_id_key UNIQUE(organization_id,cash_register_id,id);

DROP INDEX IF EXISTS public.sesiones_caja_unica_abierta_idx;
CREATE UNIQUE INDEX sesiones_caja_one_open_per_register_key
  ON public.sesiones_caja(organization_id,cash_register_id)
  WHERE estado='ABIERTA';
CREATE INDEX sesiones_caja_org_branch_fecha_idx
  ON public.sesiones_caja(organization_id,branch_id,fecha_apertura DESC);

CREATE OR REPLACE FUNCTION private.enforce_cash_session_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.current_organization_id();
  v_register public.cash_registers;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
       OR NEW.cash_register_id IS DISTINCT FROM OLD.cash_register_id OR NEW.usuario_id IS DISTINCT FROM OLD.usuario_id THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cash session context is immutable';
    END IF;
    RETURN NEW;
  END IF;

  v_org:=COALESCE(v_org,NEW.organization_id);
  IF v_org IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Organization context required for cash session'; END IF;

  IF NEW.cash_register_id IS NULL THEN
    SELECT c.* INTO v_register
    FROM public.cash_registers c
    JOIN public.branches b ON b.organization_id=c.organization_id AND b.id=c.branch_id
    WHERE c.organization_id=v_org AND c.is_default AND c.status='active'
      AND b.is_main AND b.status='active';
  ELSE
    SELECT c.* INTO v_register
    FROM public.cash_registers c
    JOIN public.branches b ON b.organization_id=c.organization_id AND b.id=c.branch_id
    WHERE c.organization_id=v_org AND c.id=NEW.cash_register_id
      AND c.status='active' AND b.status='active';
  END IF;
  IF v_register.id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Active cash register not available in current organization'; END IF;

  NEW.organization_id:=v_org;
  NEW.branch_id:=v_register.branch_id;
  NEW.cash_register_id:=v_register.id;
  IF auth.uid() IS NOT NULL THEN NEW.usuario_id:=auth.uid(); END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_cash_session_context() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER sesiones_caja_enforce_context
BEFORE INSERT OR UPDATE ON public.sesiones_caja
FOR EACH ROW EXECUTE FUNCTION private.enforce_cash_session_context();

ALTER TABLE public.sesiones_caja ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sesiones_caja_select_empleado ON public.sesiones_caja;
DROP POLICY IF EXISTS sesiones_caja_insert_empleado ON public.sesiones_caja;
DROP POLICY IF EXISTS sesiones_caja_update_empleado ON public.sesiones_caja;
CREATE POLICY sesiones_caja_tenant_select ON public.sesiones_caja FOR SELECT TO authenticated
USING(private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY sesiones_caja_tenant_insert ON public.sesiones_caja FOR INSERT TO authenticated
WITH CHECK(private.has_permission('tenant.write') AND private.row_belongs_to_current_organization(organization_id) AND usuario_id=auth.uid());
CREATE POLICY sesiones_caja_tenant_update ON public.sesiones_caja FOR UPDATE TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND (usuario_id=auth.uid() OR private.has_permission('tenant.admin')))
WITH CHECK(private.row_belongs_to_current_organization(organization_id) AND (usuario_id=auth.uid() OR private.has_permission('tenant.admin')));

REVOKE ALL ON TABLE public.sesiones_caja FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON TABLE public.sesiones_caja TO authenticated;

-- Una branch con cajas activas tampoco puede desactivarse.
CREATE OR REPLACE FUNCTION public.update_branch_v1(p_branch_id uuid,p_name text,p_address text DEFAULT NULL,p_status text DEFAULT 'active')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_org uuid:=private.require_current_organization_id(); v_status text:=lower(btrim(p_status)); v_branch public.branches;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN RAISE EXCEPTION 'Only tenant admin can update branches' USING ERRCODE='42501'; END IF;
  IF v_status NOT IN('active','inactive') THEN RAISE EXCEPTION 'Invalid branch status' USING ERRCODE='22023'; END IF;
  IF v_status='inactive' AND EXISTS(SELECT 1 FROM public.almacenes a WHERE a.organization_id=v_org AND a.branch_id=p_branch_id AND COALESCE(a.activo,true)) THEN
    RAISE EXCEPTION 'Branch has active warehouses' USING ERRCODE='23514';
  END IF;
  IF v_status='inactive' AND EXISTS(SELECT 1 FROM public.cash_registers c WHERE c.organization_id=v_org AND c.branch_id=p_branch_id AND c.status='active') THEN
    RAISE EXCEPTION 'Branch has active cash registers' USING ERRCODE='23514';
  END IF;
  UPDATE public.branches SET name=btrim(p_name),address=NULLIF(btrim(p_address),''),status=v_status
  WHERE organization_id=v_org AND id=p_branch_id RETURNING * INTO v_branch;
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not available in current organization' USING ERRCODE='P0002'; END IF;
  RETURN to_jsonb(v_branch);
END;
$$;
REVOKE ALL ON FUNCTION public.update_branch_v1(uuid,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.update_branch_v1(uuid,text,text,text) TO authenticated;

COMMIT;
