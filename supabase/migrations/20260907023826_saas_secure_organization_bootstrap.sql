-- Fase 1.4 SaaS: bootstrap transaccional de una nueva organizacion.
-- La configuracion legacy se expande de forma aditiva; el backfill/runtime se migra despues.
BEGIN;

-- configuracion_negocio deja de depender de un identificador constante para nuevas filas.
CREATE SEQUENCE IF NOT EXISTS public.configuracion_negocio_id_seq AS integer;

SELECT setval(
  'public.configuracion_negocio_id_seq',
  COALESCE((SELECT max(id)::bigint FROM public.configuracion_negocio), 1),
  EXISTS (SELECT 1 FROM public.configuracion_negocio)
);

ALTER SEQUENCE public.configuracion_negocio_id_seq
  OWNED BY public.configuracion_negocio.id;

ALTER TABLE public.configuracion_negocio
  ALTER COLUMN id SET DEFAULT nextval('public.configuracion_negocio_id_seq'::regclass),
  ADD COLUMN organization_id uuid;

ALTER TABLE public.configuracion_negocio
  ADD CONSTRAINT configuracion_negocio_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT configuracion_negocio_organization_id_key
    UNIQUE (organization_id),
  ADD CONSTRAINT configuracion_negocio_organization_id_id_key
    UNIQUE (organization_id, id);

COMMENT ON COLUMN public.configuracion_negocio.organization_id IS
  'Tenant propietario. NULL solo durante la transicion/backfill de la fila legacy.';

-- business_capabilities deja de estar limitado a una unica fila y recibe tenant directo.
ALTER TABLE public.business_capabilities
  DROP CONSTRAINT IF EXISTS business_capabilities_singleton,
  ADD COLUMN organization_id uuid;

ALTER TABLE public.business_capabilities
  ADD CONSTRAINT business_capabilities_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT business_capabilities_organization_id_key
    UNIQUE (organization_id),
  ADD CONSTRAINT business_capabilities_organization_business_fkey
    FOREIGN KEY (organization_id, business_id)
    REFERENCES public.configuracion_negocio(organization_id, id)
    ON DELETE RESTRICT;

COMMENT ON COLUMN public.business_capabilities.organization_id IS
  'Tenant propietario. Para filas nuevas es directo; la fila legacy se backfillea en la migracion de dominio.';

CREATE OR REPLACE FUNCTION public.bootstrap_organization_v1(
  p_display_name text,
  p_country_code text,
  p_currency_code text,
  p_timezone text,
  p_legal_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_configuration_id integer;
  v_display_name text := nullif(btrim(p_display_name), '');
  v_country_code text := upper(nullif(btrim(p_country_code), ''));
  v_currency_code text := upper(nullif(btrim(p_currency_code), ''));
  v_timezone text := nullif(btrim(p_timezone), '');
  v_legal_name text := nullif(btrim(p_legal_name), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '28000',
      MESSAGE = 'Authentication required for organization bootstrap';
  END IF;

  IF v_display_name IS NULL OR v_country_code IS NULL
     OR v_currency_code IS NULL OR v_timezone IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'display_name, country_code, currency_code and timezone are required';
  END IF;

  -- Serializa bootstraps concurrentes del mismo usuario autenticado.
  PERFORM 1
  FROM auth.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = '28000',
      MESSAGE = 'Authenticated user no longer exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.app_users
    WHERE user_id = v_user_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Authenticated user already belongs to an organization';
  END IF;

  -- Una identidad legacy debe migrarse, no crear silenciosamente otra empresa.
  IF EXISTS (
    SELECT 1
    FROM public.empleados
    WHERE auth_id = v_user_id OR app_user_id = v_user_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Legacy employee identity must be migrated before organization bootstrap';
  END IF;

  INSERT INTO public.organizations (
    legal_name,
    display_name,
    country_code,
    currency_code,
    timezone
  ) VALUES (
    v_legal_name,
    v_display_name,
    v_country_code,
    v_currency_code,
    v_timezone
  )
  RETURNING id INTO v_organization_id;

  INSERT INTO public.app_users (
    user_id,
    organization_id,
    status,
    base_role
  ) VALUES (
    v_user_id,
    v_organization_id,
    'active',
    'admin'
  );

  INSERT INTO public.configuracion_negocio (
    organization_id,
    razon_social,
    nombre_comercial
  ) VALUES (
    v_organization_id,
    v_legal_name,
    v_display_name
  )
  RETURNING id INTO v_configuration_id;

  INSERT INTO public.business_capabilities (
    business_id,
    organization_id
  ) VALUES (
    v_configuration_id,
    v_organization_id
  );

  RETURN v_organization_id;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_organization_v1(text, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bootstrap_organization_v1(text, text, text, text, text)
  TO authenticated;

COMMENT ON FUNCTION public.bootstrap_organization_v1(text, text, text, text, text) IS
  'Crea atomicamente organization, app_user admin, configuracion inicial y capacidades default para auth.uid(). No acepta organization_id del cliente.';

COMMIT;
