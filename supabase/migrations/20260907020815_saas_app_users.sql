-- Fase 1.2 SaaS: pertenencia de una identidad Auth a una sola organizacion.
-- No migra todavia empleados.auth_id ni crea membresias multiempresa.
BEGIN;

CREATE TABLE public.app_users (
  user_id uuid PRIMARY KEY
    REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL
    REFERENCES public.organizations(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active',
  base_role text NOT NULL DEFAULT 'operador',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT app_users_organization_user_key
    UNIQUE (organization_id, user_id),
  CONSTRAINT app_users_status_valid
    CHECK (status IN ('active', 'disabled')),
  CONSTRAINT app_users_base_role_valid
    CHECK (base_role IN ('admin', 'operador'))
);

COMMENT ON TABLE public.app_users IS
  'Acceso StOmni por identidad Auth. V1: cada user_id pertenece a una sola organizacion.';
COMMENT ON COLUMN public.app_users.user_id IS
  'Identidad canonica de Supabase Auth; PK para impedir multiples organizaciones en V1.';
COMMENT ON COLUMN public.app_users.organization_id IS
  'Tenant autorizado del usuario. Es inmutable durante la vida de la membresia V1.';
COMMENT ON COLUMN public.app_users.base_role IS
  'Rol base transitorio V1; evolucionara al modelo configurable de permisos.';

ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;

-- Sin policies de cliente hasta que los helpers tenant-aware esten implementados.
REVOKE ALL ON TABLE public.app_users FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public._app_users_before_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'app user id is immutable'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'app user organization is immutable in V1'
      USING ERRCODE = '23514';
  END IF;

  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public._app_users_before_update()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_app_users_before_update
BEFORE UPDATE ON public.app_users
FOR EACH ROW
EXECUTE FUNCTION public._app_users_before_update();

COMMIT;
