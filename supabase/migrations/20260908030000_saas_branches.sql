-- Fase 4.1 SaaS: sucursales por organización.
-- No enlaza todavía almacenes, cajas ni empleados; esas relaciones pertenecen
-- a F4.2, F4.3 y F4.4 respectivamente.
BEGIN;

CREATE TABLE public.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  address text,
  is_main boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT branches_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  CONSTRAINT branches_organization_id_id_key
    UNIQUE (organization_id, id),
  CONSTRAINT branches_code_format
    CHECK (code = upper(btrim(code)) AND code ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'),
  CONSTRAINT branches_name_not_blank
    CHECK (btrim(name) <> '' AND char_length(btrim(name)) <= 120),
  CONSTRAINT branches_address_not_blank
    CHECK (address IS NULL OR btrim(address) <> ''),
  CONSTRAINT branches_status_valid
    CHECK (status IN ('active', 'inactive'))
);

CREATE UNIQUE INDEX branches_organization_code_key
  ON public.branches (organization_id, code);

CREATE UNIQUE INDEX branches_one_main_per_organization_key
  ON public.branches (organization_id)
  WHERE is_main;

CREATE INDEX branches_organization_status_idx
  ON public.branches (organization_id, status);

COMMENT ON TABLE public.branches IS
  'Sucursales de una organización StOmni. Ownership directo por organization_id.';
COMMENT ON COLUMN public.branches.code IS
  'Código corto estable y único dentro de la organización.';
COMMENT ON COLUMN public.branches.is_main IS
  'Sucursal principal. Existe como máximo una por organización.';

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.branches FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.branches TO authenticated;

CREATE OR REPLACE FUNCTION public._branches_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.code := upper(btrim(NEW.code));
  NEW.name := btrim(NEW.name);
  NEW.address := NULLIF(btrim(NEW.address), '');

  IF TG_OP = 'UPDATE' THEN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'branch id is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
      RAISE EXCEPTION 'branch organization is immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.is_main AND NEW.status <> 'active' THEN
      RAISE EXCEPTION 'main branch must remain active' USING ERRCODE='23514';
    END IF;
    NEW.updated_at := clock_timestamp();
  END IF;

  IF NEW.is_main AND NEW.status <> 'active' THEN
    RAISE EXCEPTION 'main branch must be active' USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._branches_before_write()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_branches_before_write
BEFORE INSERT OR UPDATE ON public.branches
FOR EACH ROW EXECUTE FUNCTION public._branches_before_write();

-- Toda organización ya existente recibe una sucursal principal. La operación es
-- deterministicamente idempotente por (organization_id, code).
INSERT INTO public.branches (organization_id, code, name, is_main, status)
SELECT o.id, 'MAIN', 'Principal', true, 'active'
FROM public.organizations o
ON CONFLICT (organization_id, code) DO NOTHING;

-- Una organización creada después de esta migración recibe su sucursal principal
-- dentro de la misma transacción de bootstrap.
CREATE OR REPLACE FUNCTION public._organization_create_main_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.branches (organization_id, code, name, is_main, status)
  VALUES (NEW.id, 'MAIN', 'Principal', true, 'active')
  ON CONFLICT (organization_id, code) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._organization_create_main_branch()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_organization_create_main_branch
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION public._organization_create_main_branch();

CREATE POLICY branches_tenant_select ON public.branches
FOR SELECT TO authenticated
USING (
  private.row_belongs_to_current_organization(organization_id)
  AND private.has_permission('tenant.read')
);

-- Mutaciones únicamente mediante RPC: el cliente no aporta organization_id.
CREATE OR REPLACE FUNCTION public.create_branch_v1(
  p_code text,
  p_name text,
  p_address text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_branch public.branches;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can create branches' USING ERRCODE='42501';
  END IF;

  INSERT INTO public.branches (organization_id, code, name, address, is_main, status)
  VALUES (v_org, upper(btrim(p_code)), btrim(p_name), NULLIF(btrim(p_address),''), false, 'active')
  RETURNING * INTO v_branch;

  RETURN jsonb_build_object(
    'id', v_branch.id,
    'organization_id', v_branch.organization_id,
    'code', v_branch.code,
    'name', v_branch.name,
    'address', v_branch.address,
    'is_main', v_branch.is_main,
    'status', v_branch.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_branch_v1(
  p_branch_id uuid,
  p_name text,
  p_address text DEFAULT NULL,
  p_status text DEFAULT 'active'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_branch public.branches;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can update branches' USING ERRCODE='42501';
  END IF;

  UPDATE public.branches
  SET name=btrim(p_name),
      address=NULLIF(btrim(p_address),''),
      status=lower(btrim(p_status))
  WHERE organization_id=v_org AND id=p_branch_id
  RETURNING * INTO v_branch;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Branch not available in current organization' USING ERRCODE='P0002';
  END IF;

  RETURN to_jsonb(v_branch);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_main_branch_v1(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_branch public.branches;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can set main branch' USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_branch
  FROM public.branches
  WHERE organization_id=v_org AND id=p_branch_id AND status='active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active branch not available in current organization' USING ERRCODE='P0002';
  END IF;

  UPDATE public.branches
  SET is_main=false
  WHERE organization_id=v_org AND is_main AND id<>p_branch_id;

  UPDATE public.branches
  SET is_main=true
  WHERE organization_id=v_org AND id=p_branch_id
  RETURNING * INTO v_branch;

  RETURN to_jsonb(v_branch);
END;
$$;

REVOKE ALL ON FUNCTION public.create_branch_v1(text,text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_branch_v1(uuid,text,text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_main_branch_v1(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_branch_v1(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_branch_v1(uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_main_branch_v1(uuid) TO authenticated;

COMMIT;
