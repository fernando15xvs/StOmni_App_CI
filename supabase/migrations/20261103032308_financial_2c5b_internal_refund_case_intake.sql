-- 2C5B-A: solicitudes de devolución pendientes de conciliación.
-- NO mueve dinero, NO emite evento financiero y NO reserva excedente.
-- 2C6 NC + liquidación bancaria/caja deben preceder el desembolso.
CREATE TABLE private.venta_solicitudes_devolucion (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id uuid NOT NULL,
 venta_id bigint NOT NULL,
 nota_credito_id uuid NOT NULL,
 request_id uuid NOT NULL,
 actor_id uuid NOT NULL,
 moneda text NOT NULL DEFAULT 'PEN' CHECK (moneda='PEN'),
 monto_solicitado numeric(14,2) NOT NULL
   CHECK (monto_solicitado>0 AND monto_solicitado<=999999999999.99),
 motivo text NOT NULL CHECK (length(btrim(motivo)) BETWEEN 10 AND 500),
 estado text NOT NULL DEFAULT 'pendiente_conciliacion'
   CHECK (estado='pendiente_conciliacion'),
 fingerprint text NOT NULL CHECK(length(fingerprint)=64),
 solicitado_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT devolucion_2c5b_cuenta_fk
   FOREIGN KEY (organization_id,venta_id)
   REFERENCES public.venta_cuentas_financieras(organization_id,venta_id)
   ON DELETE RESTRICT,
 CONSTRAINT devolucion_2c5b_nota_fk
   FOREIGN KEY (organization_id,venta_id,nota_credito_id)
   REFERENCES public.notas_credito(organization_id,venta_id,id)
   ON DELETE RESTRICT,
 CONSTRAINT devolucion_2c5b_request_unique UNIQUE(organization_id,request_id),
 CONSTRAINT devolucion_2c5b_nota_unique UNIQUE(organization_id,venta_id,nota_credito_id)
);

CREATE INDEX devolucion_2c5b_sale_lookup
 ON private.venta_solicitudes_devolucion(organization_id,venta_id,solicitado_at);

ALTER TABLE private.venta_solicitudes_devolucion ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.venta_solicitudes_devolucion
 FROM PUBLIC,anon,authenticated,service_role;

CREATE TRIGGER devolucion_2c5b_immutable
 BEFORE UPDATE OR DELETE ON private.venta_solicitudes_devolucion
 FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();

CREATE FUNCTION private.financial_2c5b_open_refund_case(
 p_organization_id uuid,
 p_venta_id bigint,
 p_nota_credito_id uuid,
 p_request_id uuid,
 p_monto numeric,
 p_motivo text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
SET "TimeZone"='UTC'
AS $fn$
DECLARE
 v_actor uuid:=auth.uid();
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_nc public.notas_credito%ROWTYPE;
 v_case private.venta_solicitudes_devolucion%ROWTYPE;
 v_payload text;
 v_fingerprint text;
 v_response jsonb;
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL OR
    p_nota_credito_id IS NULL OR p_request_id IS NULL OR
    p_monto IS NULL OR p_motivo IS NULL OR v_actor IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Faltan identidad JWT o datos obligatorios de solicitud de devolución';
 END IF;
 IF p_monto<=0 OR p_monto<>round(p_monto,2)
    OR p_monto>999999999999.99 THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='El importe de devolución debe tener centavos exactos y ser positivo';
 END IF;
 IF length(btrim(p_motivo)) NOT BETWEEN 10 AND 500 THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Motivo de devolución debe tener entre 10 y 500 caracteres';
 END IF;
 IF private.current_organization_id() IS DISTINCT FROM p_organization_id
    OR NOT private.has_permission('tenant.admin') THEN
   RAISE EXCEPTION USING ERRCODE='42501',
     MESSAGE='Solo administración activa de la organización puede solicitar devolución';
 END IF;

 v_payload:=pg_catalog.jsonb_build_object(
  'organization_id',p_organization_id,'venta_id',p_venta_id,
  'nota_credito_id',p_nota_credito_id,'actor',v_actor,
  'moneda','PEN','monto',p_monto::numeric(14,2),'motivo',btrim(p_motivo)
 )::text;
 v_fingerprint:=pg_catalog.encode(extensions.digest(v_payload,'sha256'),'hex');

 -- Serializa todas las solicitudes de una venta mediante bloqueo de cuenta.
 SELECT cf.* INTO v_account FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=p_organization_id AND cf.venta_id=p_venta_id
 FOR UPDATE;
 IF NOT FOUND OR v_account.moneda<>'PEN'
    OR v_account.estado_conciliacion<>'conciliada' THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera no conciliada o moneda no PEN';
 END IF;

 SELECT * INTO v_case
 FROM private.venta_solicitudes_devolucion c
 WHERE c.organization_id=p_organization_id
   AND c.request_id=p_request_id;
 IF FOUND THEN
   IF v_case.venta_id IS DISTINCT FROM p_venta_id
      OR v_case.nota_credito_id IS DISTINCT FROM p_nota_credito_id
      OR v_case.actor_id IS DISTINCT FROM v_actor
      OR v_case.fingerprint IS DISTINCT FROM v_fingerprint THEN
     RAISE EXCEPTION USING ERRCODE='23505',
       MESSAGE='request_id de devolución ya utilizado con otros datos';
   END IF;
   RETURN pg_catalog.jsonb_build_object(
     'success',true,'idempotent',true,'caso_id',v_case.id,
     'venta_id',v_case.venta_id,'nota_credito_id',v_case.nota_credito_id,
     'request_id',v_case.request_id,'monto_solicitado',v_case.monto_solicitado,
     'moneda','PEN','estado',v_case.estado,'dinero_entregado',false,
     'excedente_reservado',false
   );
 END IF;

 SELECT nc.* INTO v_nc FROM public.notas_credito nc
 WHERE nc.organization_id=p_organization_id AND nc.venta_id=p_venta_id
   AND nc.id=p_nota_credito_id
 FOR SHARE;
 IF NOT FOUND OR v_nc.estado<>'aceptado'
    OR v_nc.aceptado_at IS NULL OR NOT v_nc.afecta_dinero
    OR v_nc.estado_baja_tributaria<>'ninguna'
    OR v_nc.moneda<>'PEN' OR v_nc.total<=0
    OR v_nc.total<>round(v_nc.total,2)
    OR p_monto>v_nc.total
    OR p_monto>v_account.cobros_netos THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='NC no aceptada o monto no sustentado; no se registra devolución';
 END IF;
 IF EXISTS(
  SELECT 1 FROM private.venta_solicitudes_devolucion c
  WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
    AND c.nota_credito_id=p_nota_credito_id
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23505',
     MESSAGE='Esta nota de crédito ya tiene una solicitud de devolución';
 END IF;

 INSERT INTO private.venta_solicitudes_devolucion(
  organization_id,venta_id,nota_credito_id,request_id,
  actor_id,monto_solicitado,motivo,fingerprint
 ) VALUES(
  p_organization_id,p_venta_id,p_nota_credito_id,p_request_id,
  v_actor,p_monto,btrim(p_motivo),v_fingerprint
 ) RETURNING * INTO v_case;

 v_response:=pg_catalog.jsonb_build_object(
  'success',true,'idempotent',false,'caso_id',v_case.id,
  'venta_id',v_case.venta_id,'nota_credito_id',v_case.nota_credito_id,
  'request_id',v_case.request_id,'monto_solicitado',v_case.monto_solicitado,
  'moneda','PEN','estado',v_case.estado,'dinero_entregado',false,
  'excedente_reservado',false
 );
 RETURN v_response;
END;
$fn$;

REVOKE ALL ON FUNCTION private.financial_2c5b_open_refund_case(
 uuid,bigint,uuid,uuid,numeric,text
) FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON TABLE private.venta_solicitudes_devolucion
 IS 'Solo expediente interno. No descuenta cobros, no reserva excedente ni confirma transferencia bancaria/egreso de caja.';
COMMENT ON FUNCTION private.financial_2c5b_open_refund_case(uuid,bigint,uuid,uuid,numeric,text)
 IS '2C5B-A expediente pendiente de conciliación, sin ejecución monetaria y sin exposición al cliente.';
