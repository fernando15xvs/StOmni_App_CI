-- Fase 4.2 SaaS: almacenes por sucursal.
BEGIN;

ALTER TABLE public.almacenes
  ADD COLUMN branch_id uuid;

COMMENT ON COLUMN public.almacenes.branch_id IS
  'Sucursal operativa a la que pertenece el almacén. Debe pertenecer al mismo organization_id.';

-- Todo almacén histórico se asigna a la sucursal principal creada en F4.1.
UPDATE public.almacenes a
SET branch_id = b.id
FROM public.branches b
WHERE a.branch_id IS NULL
  AND b.organization_id = a.organization_id
  AND b.is_main = true
  AND b.status = 'active';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.almacenes WHERE branch_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Unscoped warehouse remains without a main branch';
  END IF;
END;
$$;

ALTER TABLE public.almacenes
  ALTER COLUMN branch_id SET NOT NULL,
  ADD CONSTRAINT almacenes_organization_branch_fkey
    FOREIGN KEY (organization_id, branch_id)
    REFERENCES public.branches(organization_id, id)
    ON DELETE RESTRICT;

CREATE INDEX almacenes_organization_branch_active_idx
  ON public.almacenes(organization_id, branch_id, activo);

-- Se ejecuta de forma independiente al trigger tenant de F3.4. Para clientes
-- autenticados deriva organization_id desde auth; para operaciones privilegiadas
-- exige que NEW.organization_id ya esté presente.
CREATE OR REPLACE FUNCTION private.enforce_warehouse_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_current_org uuid := private.current_organization_id();
  v_org uuid;
  v_branch uuid;
BEGIN
  IF TG_OP='UPDATE' AND NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='warehouse organization is immutable';
  END IF;

  v_org := COALESCE(v_current_org, NEW.organization_id);
  IF v_org IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Organization context required for warehouse branch';
  END IF;

  IF v_current_org IS NOT NULL
     AND NEW.organization_id IS NOT NULL
     AND NEW.organization_id IS DISTINCT FROM v_current_org THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant warehouse write is not allowed';
  END IF;

  IF NEW.branch_id IS NULL THEN
    SELECT b.id INTO v_branch
    FROM public.branches b
    WHERE b.organization_id=v_org
      AND b.is_main=true
      AND b.status='active';

    IF v_branch IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Active main branch required for warehouse';
    END IF;
    NEW.branch_id := v_branch;
  ELSE
    SELECT b.id INTO v_branch
    FROM public.branches b
    WHERE b.organization_id=v_org
      AND b.id=NEW.branch_id
      AND b.status='active';

    IF v_branch IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Warehouse branch not available in current organization';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enforce_warehouse_branch()
  FROM PUBLIC, anon, authenticated;

-- Nombre zz_* garantiza que el trigger tenant de F3.4 ejecute antes en la misma
-- fase BEFORE cuando PostgreSQL ordena triggers por nombre.
CREATE TRIGGER zz_almacenes_enforce_branch
BEFORE INSERT OR UPDATE ON public.almacenes
FOR EACH ROW EXECUTE FUNCTION private.enforce_warehouse_branch();

-- Una sucursal con almacenes activos no puede desactivarse. Reemplaza el RPC de
-- F4.1 sin cambiar su firma ni el contrato cliente.
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
  v_status text := lower(btrim(p_status));
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can update branches' USING ERRCODE='42501';
  END IF;

  IF v_status NOT IN ('active','inactive') THEN
    RAISE EXCEPTION 'Invalid branch status' USING ERRCODE='22023';
  END IF;

  IF v_status='inactive' AND EXISTS (
    SELECT 1 FROM public.almacenes a
    WHERE a.organization_id=v_org
      AND a.branch_id=p_branch_id
      AND COALESCE(a.activo,true)=true
  ) THEN
    RAISE EXCEPTION 'Branch has active warehouses' USING ERRCODE='23514';
  END IF;

  UPDATE public.branches
  SET name=btrim(p_name),
      address=NULLIF(btrim(p_address),''),
      status=v_status
  WHERE organization_id=v_org AND id=p_branch_id
  RETURNING * INTO v_branch;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Branch not available in current organization' USING ERRCODE='P0002';
  END IF;

  RETURN to_jsonb(v_branch);
END;
$$;

REVOKE ALL ON FUNCTION public.update_branch_v1(uuid,text,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_branch_v1(uuid,text,text,text)
  TO authenticated;

COMMIT;
