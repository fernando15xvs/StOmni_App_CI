-- Fase 1.1 SaaS: entidad raiz de tenant.
-- Aditiva: no migra configuracion_negocio ni datos operativos existentes.
BEGIN;

CREATE TABLE public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name text,
  display_name text NOT NULL,
  country_code text NOT NULL,
  currency_code text NOT NULL,
  timezone text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organizations_display_name_not_blank
    CHECK (btrim(display_name) <> ''),
  CONSTRAINT organizations_legal_name_not_blank
    CHECK (legal_name IS NULL OR btrim(legal_name) <> ''),
  CONSTRAINT organizations_country_code_format
    CHECK (country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT organizations_currency_code_format
    CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT organizations_timezone_not_blank
    CHECK (btrim(timezone) <> ''),
  CONSTRAINT organizations_status_valid
    CHECK (status IN ('active', 'suspended', 'closed'))
);

COMMENT ON TABLE public.organizations IS
  'Raiz multi-tenant de StOmni. Cada fila representa una empresa aislada.';
COMMENT ON COLUMN public.organizations.id IS
  'Identificador UUID opaco e inmutable del tenant.';
COMMENT ON COLUMN public.organizations.country_code IS
  'Codigo ISO 3166-1 alpha-2 en mayusculas.';
COMMENT ON COLUMN public.organizations.currency_code IS
  'Codigo ISO 4217 en mayusculas.';
COMMENT ON COLUMN public.organizations.timezone IS
  'Nombre de zona horaria IANA configurado para la empresa.';

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

-- Defense in depth: la tabla no se expone a clientes hasta Fase 2.
REVOKE ALL ON TABLE public.organizations FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public._organizations_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'organization id is immutable'
      USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_timezone_names AS tz
    WHERE tz.name = NEW.timezone
  ) THEN
    RAISE EXCEPTION 'invalid organization timezone: %', NEW.timezone
      USING ERRCODE = '22023';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := clock_timestamp();
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public._organizations_before_write()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_organizations_before_write
BEFORE INSERT OR UPDATE ON public.organizations
FOR EACH ROW
EXECUTE FUNCTION public._organizations_before_write();

COMMIT;
