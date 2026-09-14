-- Fase 3.7 SaaS: los artefactos fiscales nuevos se guardan bajo
-- <organization_id>/... sin reescribir paths legacy ya existentes.
BEGIN;

CREATE OR REPLACE FUNCTION private.normalize_fiscal_storage_paths()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_prefix text;
BEGIN
  -- En INSERT los paths normalmente nacen NULL y el trigger de ownership puede
  -- completar organization_id después. La normalización relevante ocurre cuando
  -- Edge persiste el path tras subir el archivo.
  IF NEW.organization_id IS NULL THEN
    IF NEW.xml_path IS NOT NULL OR NEW.pdf_path IS NOT NULL OR NEW.cdr_path IS NOT NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = '23502',
        MESSAGE = 'Fiscal storage path requires organization_id';
    END IF;
    RETURN NEW;
  END IF;

  v_prefix := NEW.organization_id::text || '/';

  IF NULLIF(btrim(NEW.xml_path), '') IS NOT NULL
     AND NEW.xml_path NOT LIKE v_prefix || '%' THEN
    NEW.xml_path := v_prefix || ltrim(NEW.xml_path, '/');
  END IF;

  IF NULLIF(btrim(NEW.pdf_path), '') IS NOT NULL
     AND NEW.pdf_path NOT LIKE v_prefix || '%' THEN
    NEW.pdf_path := v_prefix || ltrim(NEW.pdf_path, '/');
  END IF;

  IF NULLIF(btrim(NEW.cdr_path), '') IS NOT NULL
     AND NEW.cdr_path NOT LIKE v_prefix || '%' THEN
    NEW.cdr_path := v_prefix || ltrim(NEW.cdr_path, '/');
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.normalize_fiscal_storage_paths()
  FROM PUBLIC, anon, authenticated;

-- Prefijo zz_: PostgreSQL ejecuta triggers BEFORE ROW del mismo tipo en orden
-- alfabético; así *_enforce_organization_id corre antes que este normalizador.
-- La función es idempotente, por lo que puede ejecutarse en todo UPDATE.
CREATE TRIGGER zz_comprobantes_fiscal_storage_paths
BEFORE INSERT OR UPDATE
ON public.comprobantes_electronicos
FOR EACH ROW EXECUTE FUNCTION private.normalize_fiscal_storage_paths();

CREATE TRIGGER zz_notas_credito_fiscal_storage_paths
BEFORE INSERT OR UPDATE
ON public.notas_credito
FOR EACH ROW EXECUTE FUNCTION private.normalize_fiscal_storage_paths();

CREATE TRIGGER zz_guias_remision_fiscal_storage_paths
BEFORE INSERT OR UPDATE
ON public.guias_remision
FOR EACH ROW EXECUTE FUNCTION private.normalize_fiscal_storage_paths();

CREATE TRIGGER zz_procesos_tributarios_fiscal_storage_paths
BEFORE INSERT OR UPDATE
ON public.procesos_tributarios
FOR EACH ROW EXECUTE FUNCTION private.normalize_fiscal_storage_paths();

COMMENT ON FUNCTION private.normalize_fiscal_storage_paths() IS
  'Normaliza paths fiscales nuevos al namespace <organization_id>/...; no migra artefactos legacy existentes.';

COMMIT;
