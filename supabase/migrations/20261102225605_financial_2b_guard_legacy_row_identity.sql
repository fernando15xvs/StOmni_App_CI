-- Fix trigger function record type selection for venta.id BIGINT vs nota_credito.id UUID.
CREATE OR REPLACE FUNCTION private.financial_2b_guard_legacy_financial_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $body$
DECLARE
  v_org uuid;
  v_sale bigint;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    v_org := OLD.organization_id;
    IF TG_TABLE_NAME = 'ventas' THEN
      v_sale := OLD.id;
    ELSE
      v_sale := OLD.venta_id;
    END IF;
    IF v_org IS NOT NULL AND v_sale IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.venta_cuentas_financieras AS cf
       WHERE cf.organization_id = v_org AND cf.venta_id = v_sale
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE='55000',
        MESSAGE='Venta con historial financiero 2B: escritor legacy bloqueado hasta motor canónico 2C';
    END IF;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_org := NEW.organization_id;
    IF TG_TABLE_NAME = 'ventas' THEN
      v_sale := NEW.id;
    ELSE
      v_sale := NEW.venta_id;
    END IF;
    IF v_org IS NOT NULL AND v_sale IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.venta_cuentas_financieras AS cf
       WHERE cf.organization_id = v_org AND cf.venta_id = v_sale
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE='55000',
        MESSAGE='Venta con historial financiero 2B: escritor legacy bloqueado hasta motor canónico 2C';
    END IF;
    RETURN NEW;
  END IF;
  RETURN OLD;
END;
$body$;


REVOKE ALL ON FUNCTION private.financial_2b_guard_legacy_financial_write() FROM PUBLIC, anon, authenticated, service_role;
