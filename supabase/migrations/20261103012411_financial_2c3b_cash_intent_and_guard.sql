-- 2C3B-1. Amplía solo la intención privada de 2C2 para efectivo.
-- Ninguna concesión de EXECUTE a roles de cliente; transferencia intacta.
ALTER TABLE private.financial_2c2_write_intents
  ADD COLUMN actor_id uuid,
  ADD COLUMN cash_session_id uuid,
  ADD COLUMN cash_register_id uuid;

ALTER TABLE private.financial_2c2_write_intents
  DROP CONSTRAINT financial_2c2_write_intents_metodo_check;

ALTER TABLE private.financial_2c2_write_intents
  ADD CONSTRAINT financial_2c2_write_intents_metodo_check
  CHECK (metodo IN ('transferencia','efectivo'));

ALTER TABLE private.financial_2c2_write_intents
  ADD CONSTRAINT financial_2c3b_intent_cash_context_check
  CHECK (
   (metodo='transferencia' AND actor_id IS NULL AND cash_session_id IS NULL AND cash_register_id IS NULL)
   OR
   (metodo='efectivo' AND actor_id IS NOT NULL AND cash_session_id IS NOT NULL AND cash_register_id IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION private.financial_2b_guard_legacy_financial_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $guard$
DECLARE
  v_old_org uuid;
  v_new_org uuid;
  v_old_sale bigint;
  v_new_sale bigint;
  v_intent private.financial_2c2_write_intents%ROWTYPE;
  v_expected_status text;
BEGIN
  IF TG_TABLE_NAME='ventas' THEN
    IF TG_OP<>'INSERT' THEN
      v_old_org:=OLD.organization_id;
      v_old_sale:=OLD.id;
    END IF;
    IF TG_OP<>'DELETE' THEN
      v_new_org:=NEW.organization_id;
      v_new_sale:=NEW.id;
    END IF;
  ELSE
    IF TG_OP<>'INSERT' THEN
      v_old_org:=OLD.organization_id;
      v_old_sale:=OLD.venta_id;
    END IF;
    IF TG_OP<>'DELETE' THEN
      v_new_org:=NEW.organization_id;
      v_new_sale:=NEW.venta_id;
    END IF;
  END IF;

  IF TG_OP<>'INSERT' AND EXISTS (
    SELECT 1 FROM public.venta_cuentas_financieras cf
    WHERE cf.organization_id=v_old_org AND cf.venta_id=v_old_sale
  ) THEN
    IF TG_OP='DELETE'
       OR v_old_org IS DISTINCT FROM v_new_org
       OR v_old_sale IS DISTINCT FROM v_new_sale THEN
      RAISE EXCEPTION USING ERRCODE='55000',
        MESSAGE='No se puede mover ni eliminar un origen de historial canonico';
    END IF;
  END IF;

  IF v_new_org IS NOT NULL AND v_new_sale IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.venta_cuentas_financieras cf
    WHERE cf.organization_id=v_new_org AND cf.venta_id=v_new_sale
  ) THEN
    SELECT i.* INTO v_intent
      FROM private.financial_2c2_write_intents i
      WHERE i.organization_id=v_new_org AND i.venta_id=v_new_sale
        AND i.tx_id=pg_catalog.pg_current_xact_id();

    IF TG_TABLE_NAME='pagos_venta' AND TG_OP='INSERT' THEN
      IF v_intent.etapa='insert_payment'
         AND NEW.monto=v_intent.monto
         AND lower(btrim(NEW.metodo))=v_intent.metodo
         AND NEW.fecha=v_intent.fecha
         AND NEW.request_id IS NULL THEN
        IF v_intent.metodo='transferencia'
           AND NEW.cash_session_id IS NULL AND NEW.cash_register_id IS NULL THEN
          RETURN NEW;
        END IF;
        IF v_intent.metodo='efectivo'
           AND v_intent.actor_id=auth.uid()
           AND NEW.cash_session_id=v_intent.cash_session_id
           AND NEW.cash_register_id=v_intent.cash_register_id
           AND EXISTS (
             SELECT 1 FROM public.sesiones_caja s
             JOIN public.cash_registers c
               ON c.organization_id=s.organization_id
               AND c.branch_id=s.branch_id AND c.id=s.cash_register_id
             WHERE s.organization_id=v_new_org AND s.id=v_intent.cash_session_id
               AND s.usuario_id=v_intent.actor_id
               AND s.cash_register_id=v_intent.cash_register_id
               AND s.estado='ABIERTA' AND s.fecha_cierre IS NULL
               AND c.status='active'
           ) THEN
          RETURN NEW;
        END IF;
      END IF;
    END IF;

    IF TG_TABLE_NAME='ventas' AND TG_OP='UPDATE' THEN
      v_expected_status:='pendiente';
      IF v_intent.saldo_despues=0 THEN
        v_expected_status:='pagado';
      END IF;
      IF v_intent.etapa='update_sale'
         AND NEW.saldo=v_intent.saldo_despues
         AND NEW.estado=v_expected_status
         AND (to_jsonb(NEW)-'saldo'-'estado')=(to_jsonb(OLD)-'saldo'-'estado')
         AND EXISTS (
           SELECT 1
           FROM public.venta_eventos_financieros ev
           JOIN public.venta_cuentas_financieras cf
             ON cf.organization_id=ev.organization_id AND cf.venta_id=ev.venta_id
           WHERE ev.organization_id=v_new_org AND ev.venta_id=v_new_sale
             AND ev.operacion_id=v_intent.operation_id
             AND ev.pago_id=v_intent.pago_id
             AND ev.delta_cobros=v_intent.monto
             AND cf.saldo_pendiente=v_intent.saldo_despues
         ) THEN
        RETURN NEW;
      END IF;
    END IF;

    RAISE EXCEPTION USING ERRCODE='55000',
      MESSAGE='Escritor legacy bloqueado: requiere operacion canonica auditada';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$guard$;

REVOKE ALL ON FUNCTION private.financial_2b_guard_legacy_financial_write()
  FROM PUBLIC,anon,authenticated,service_role;

REVOKE ALL ON TABLE private.financial_2c2_write_intents
  FROM PUBLIC,anon,authenticated,service_role;
