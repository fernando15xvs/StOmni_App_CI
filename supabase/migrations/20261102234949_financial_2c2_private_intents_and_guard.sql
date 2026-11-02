-- 2C2A: canal de autorizacion transaccional para escritores canonicos.
-- Sin derechos a anon/authenticated/service_role; nunca bypass por GUC.
ALTER TABLE public.venta_operaciones_financieras
  ADD COLUMN IF NOT EXISTS resultado_payload jsonb;

CREATE TABLE private.financial_2c2_write_intents (
 organization_id uuid NOT NULL,
 venta_id bigint NOT NULL,
 tx_id xid8 NOT NULL,
 operation_id uuid NOT NULL,
 request_id uuid NOT NULL,
 monto numeric(14,2) NOT NULL CHECK (monto > 0),
 metodo text NOT NULL CHECK (metodo = 'transferencia'),
 fecha timestamptz NOT NULL,
 saldo_despues numeric(14,2) NOT NULL CHECK (saldo_despues >= 0),
 etapa text NOT NULL CHECK (etapa IN ('insert_payment','update_sale')),
 pago_id bigint,
 creado_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT financial_2c2_intents_pkey PRIMARY KEY (organization_id,venta_id,tx_id),
 CONSTRAINT financial_2c2_intent_operation_fk FOREIGN KEY
 (organization_id,venta_id,operation_id)
 REFERENCES public.venta_operaciones_financieras(organization_id,venta_id,id)
 ON DELETE RESTRICT
);
CREATE INDEX financial_2c2_intent_operation_idx
 ON private.financial_2c2_write_intents(organization_id,venta_id,operation_id);
ALTER TABLE private.financial_2c2_write_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.financial_2c2_write_intents FROM PUBLIC,anon,authenticated,service_role;

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
        AND NEW.request_id IS NULL
        AND NEW.cash_session_id IS NULL
        AND NEW.cash_register_id IS NULL THEN
        RETURN NEW;
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
