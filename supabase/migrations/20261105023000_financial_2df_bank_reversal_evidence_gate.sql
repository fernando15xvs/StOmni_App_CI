-- 2D-F: fail-closed bank reversal evidence custody.
-- NEVER accessible to Data API, mobile, anon, authenticated or service_role.
-- The trusted bank reconciliation worker must independently verify its
-- bank API/signed webhook BEFORE inserting an attestation using a restricted
-- direct database identity. A SHA256 digest is an audit checksum, NOT a bank
-- signature. There is no automatic bank verification in PostgreSQL.
CREATE TABLE private.financial_2df_bank_reversal_evidence (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 organization_id uuid NOT NULL REFERENCES public.organizations(id),
 venta_id bigint NOT NULL,
 original_event_id uuid NOT NULL,
 bank_reversal_ref text NOT NULL CHECK (bank_reversal_ref ~ '^[A-Za-z0-9._:/-]{8,120}$'),
 provider text NOT NULL CHECK (provider ~ '^[A-Za-z0-9._-]{3,60}$'),
 provider_event_id text NOT NULL CHECK (length(provider_event_id) BETWEEN 8 AND 160),
 verification_source text NOT NULL CHECK (verification_source IN ('bank_api','signed_webhook')),
 provider_payload_sha256 text NOT NULL CHECK (provider_payload_sha256 ~ '^[0-9a-f]{64}$'),
 currency text NOT NULL CHECK (currency='PEN'),
 amount numeric NOT NULL CHECK(amount>0 AND amount=round(amount,2)),
 effective_at timestamptz NOT NULL,
 verified_at timestamptz NOT NULL,
 verified_by text NOT NULL CHECK (verified_by ~ '^[A-Za-z0-9._:/-]{4,120}$'),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE (organization_id,venta_id,original_event_id),
 UNIQUE (provider,provider_event_id),
 UNIQUE (organization_id,id)
);
ALTER TABLE private.financial_2df_bank_reversal_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.financial_2df_bank_reversal_evidence
 FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE private.financial_2df_bank_evidence_usages (
 evidence_id uuid PRIMARY KEY REFERENCES private.financial_2df_bank_reversal_evidence(id) ON DELETE RESTRICT,
 organization_id uuid NOT NULL,
 venta_id bigint NOT NULL,
 request_id uuid NOT NULL,
 operacion_id uuid NOT NULL,
 evento_id uuid NOT NULL,
 used_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY (organization_id,evidence_id)
 REFERENCES private.financial_2df_bank_reversal_evidence(organization_id,id) ON DELETE RESTRICT,
 UNIQUE (organization_id,venta_id,request_id),
 UNIQUE (organization_id,venta_id,operacion_id),
 UNIQUE (organization_id,venta_id,evento_id)
);
ALTER TABLE private.financial_2df_bank_evidence_usages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.financial_2df_bank_evidence_usages
 FROM PUBLIC,anon,authenticated,service_role;
-- Attestations/consumption receipts are append-only. Changes require a
-- separately reviewed incident remediation, not silent UPDATE/DELETE.
CREATE FUNCTION private.financial_2df_immutable_evidence()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $guard$
BEGIN
 RAISE EXCEPTION USING ERRCODE='23514',
   MESSAGE='Bank attestation and consumption receipts are immutable';
END; $guard$;
REVOKE ALL ON FUNCTION private.financial_2df_immutable_evidence()
 FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER zz_immutable_2df_bank_evidence
 BEFORE UPDATE OR DELETE ON private.financial_2df_bank_reversal_evidence
 FOR EACH ROW EXECUTE FUNCTION private.financial_2df_immutable_evidence();
CREATE TRIGGER zz_immutable_2df_bank_evidence_usage
 BEFORE UPDATE OR DELETE ON private.financial_2df_bank_evidence_usages
 FOR EACH ROW EXECUTE FUNCTION private.financial_2df_immutable_evidence();

-- Same 2D-C request contract and roles, but now requires attestation custody.
CREATE OR REPLACE FUNCTION private.financial_2dc_reverse_initial_transfer(
 p_organization_id uuid,p_venta_id bigint,p_request_id uuid,
 p_original_event_id uuid,p_efectivo_at timestamptz,p_bank_reversal_ref text
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path='' SET "TimeZone"='UTC' AS $body$
DECLARE
 v_actor uuid:=auth.uid();
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_sale public.ventas%ROWTYPE;
 v_op public.venta_operaciones_financieras%ROWTYPE;
 v_open public.venta_operaciones_financieras%ROWTYPE;
 v_origin public.venta_eventos_financieros%ROWTYPE;
 v_payment public.pagos_venta%ROWTYPE;
 v_old public.venta_cronogramas%ROWTYPE;
 v_event uuid; v_new_id uuid; v_op_id uuid; v_bank_evidence uuid;
 v_hash text; v_result jsonb;
 v_count int; v_seq bigint; v_old_total numeric;
 v_last_date date; v_last_number int; v_after numeric;
 v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL OR p_request_id IS NULL
    OR p_original_event_id IS NULL OR p_efectivo_at IS NULL
    OR p_bank_reversal_ref IS NULL
    OR p_bank_reversal_ref !~ '^[A-Za-z0-9._:/-]{8,120}$'
    OR p_efectivo_at>v_now THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Reverso inicial requiere solicitud, fecha pasada y referencia bancaria segura';
 END IF;
 IF v_actor IS NULL
   OR private.require_current_organization_id() IS DISTINCT FROM p_organization_id
   OR public.app_tiene_permiso('sales.collect') IS NOT TRUE THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Operador de cobros y organización válidos requeridos';
 END IF;
 v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.jsonb_build_object(
   'org',p_organization_id,'sale',p_venta_id,'request',p_request_id,
   'original',p_original_event_id,'effective',p_efectivo_at,
   'evidence',p_bank_reversal_ref,'actor',v_actor,
   'reason','reversal_initial_v5'
 )::text,'sha256'),'hex');
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
   p_organization_id::text||':financial-2dc:'||p_request_id::text,0));
 SELECT * INTO v_op FROM public.venta_operaciones_financieras
 WHERE organization_id=p_organization_id AND tipo='reverso' AND request_id=p_request_id;
 IF FOUND THEN
  IF v_op.venta_id IS DISTINCT FROM p_venta_id
    OR v_op.payload_hash IS DISTINCT FROM v_hash
    OR v_op.resultado<>'aplicado' OR v_op.resultado_payload IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Identificador de reverso reutilizado con diferente contenido';
  END IF;
  RETURN v_op.resultado_payload||'{"idempotent":true}'::jsonb;
 END IF;

 SELECT * INTO v_account FROM public.venta_cuentas_financieras
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id FOR UPDATE;
 SELECT * INTO v_sale FROM public.ventas
 WHERE organization_id=p_organization_id AND id=p_venta_id FOR UPDATE;
 IF v_account.venta_id IS NULL OR v_sale.id IS NULL
    OR v_account.moneda<>'PEN' OR v_account.estado_conciliacion<>'conciliada'
    OR v_account.excedente<>0 OR v_sale.fue_credito IS NOT TRUE
    OR v_sale.total IS DISTINCT FROM v_account.exigible THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Venta o cuenta no elegible para reverso inicial';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id)
   WHERE apta_para_motor) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cuenta sin auditoría canónica';
 END IF;

 SELECT * INTO v_open FROM public.venta_operaciones_financieras
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tipo='apertura' AND resultado='aplicado'
   AND metadata_apertura->>'origen'='venta_credito_v5' FOR UPDATE;
 IF NOT FOUND OR EXISTS (
    SELECT 1 FROM public.venta_operaciones_financieras op
    WHERE op.organization_id=p_organization_id AND op.venta_id=p_venta_id
      AND op.id<>v_open.id
 ) THEN
  RAISE EXCEPTION USING ERRCODE='23514',
    MESSAGE='Reverso inicial solo sin operaciones financieras posteriores';
 END IF;
 SELECT * INTO v_origin FROM public.venta_eventos_financieros
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=p_original_event_id AND operacion_id=v_open.id
   AND tipo='cobro' AND delta_exigible=0 AND delta_cobros>0
   AND pago_id IS NOT NULL FOR UPDATE;
 IF NOT FOUND OR p_efectivo_at<v_origin.efectivo_at THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Evento de anticipo no válido o fecha anterior';
 END IF;
 SELECT * INTO v_payment FROM public.pagos_venta
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=v_origin.pago_id;
 IF NOT FOUND OR lower(btrim(v_payment.metodo))<>'transferencia'
   OR v_payment.cash_register_id IS NOT NULL OR v_payment.cash_session_id IS NOT NULL
   OR v_payment.monto IS DISTINCT FROM v_origin.delta_cobros
   OR v_payment.monto<=0 OR v_payment.monto<>round(v_payment.monto,2)
   OR v_account.cobros_netos IS DISTINCT FROM v_payment.monto
   OR v_account.saldo_pendiente+v_payment.monto IS DISTINCT FROM v_account.exigible
   OR EXISTS(SELECT 1 FROM public.pagos_venta p
       WHERE p.organization_id=p_organization_id AND p.venta_id=p_venta_id
       AND p.id<>v_payment.id)
   OR EXISTS(SELECT 1 FROM public.venta_eventos_financieros ev
       WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id
       AND ev.tipo='cobro' AND ev.id<>v_origin.id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Solo anticipo inicial íntegro, único y bancario';
 END IF;
 -- 2D-F: immutable trusted bank evidence must exist, match and be unused.
 SELECT e.id INTO v_bank_evidence
 FROM private.financial_2df_bank_reversal_evidence e
 WHERE e.organization_id=p_organization_id AND e.venta_id=p_venta_id
   AND e.original_event_id=p_original_event_id
   AND e.bank_reversal_ref=p_bank_reversal_ref
   AND e.currency=v_account.moneda AND e.amount=v_payment.monto
   AND e.effective_at<=p_efectivo_at AND e.effective_at>=v_origin.efectivo_at
   AND e.verified_at<=v_now AND e.verification_source IN ('bank_api','signed_webhook')
 FOR UPDATE;
 IF v_bank_evidence IS NULL OR EXISTS (
   SELECT 1 FROM private.financial_2df_bank_evidence_usages u
   WHERE u.evidence_id=v_bank_evidence
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Reverso requiere evidencia bancaria verificada, íntegra y no consumida';
 END IF;
 SELECT * INTO v_old FROM public.venta_cronogramas
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND version=1 AND estado='vigente' FOR UPDATE;
 IF NOT FOUND OR EXISTS(SELECT 1 FROM public.venta_cronogramas
     WHERE organization_id=p_organization_id AND venta_id=p_venta_id
       AND id<>v_old.id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Solo cronograma original v1 vigente';
 END IF;
 IF EXISTS (SELECT 1 FROM public.venta_cuota_movimientos m
     WHERE m.organization_id=p_organization_id AND m.venta_id=p_venta_id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cronograma con asignaciones no permite reverso inicial';
 END IF;
 SELECT COUNT(*),COALESCE(SUM(importe_vigente),0),MAX(numero),MAX(vencimiento)
 INTO v_count,v_old_total,v_last_number,v_last_date
 FROM public.venta_cuotas WHERE organization_id=p_organization_id
  AND venta_id=p_venta_id AND cronograma_id=v_old.id;
 IF v_count<1 OR v_count>119 OR v_old_total<>v_account.saldo_pendiente
   OR v_last_number<>v_count OR v_last_date IS NULL
   OR EXISTS(SELECT 1 FROM public.venta_cuotas
     WHERE organization_id=p_organization_id AND venta_id=p_venta_id
       AND cronograma_id=v_old.id
       AND (es_legado OR vencimiento IS NULL OR importe_vigente<=0
         OR importe_vigente<>round(importe_vigente,2))) THEN
   RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cuotas originales no conciliadas';
 END IF;
 v_after:=v_account.saldo_pendiente+v_payment.monto;
 SELECT coalesce(max(secuencia),0)+1 INTO v_seq
 FROM public.venta_eventos_financieros
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;
 INSERT INTO public.venta_operaciones_financieras(
   organization_id,venta_id,tipo,request_id,actor_id,payload_hash,
   resultado,metadata_apertura
 ) VALUES (
   p_organization_id,p_venta_id,'reverso',p_request_id,v_actor,v_hash,
   'pendiente',jsonb_build_object('origen','reverso_abono_inicial_v5',
      'referencia_bancaria',p_bank_reversal_ref,'bank_evidence_id',v_bank_evidence)
 ) RETURNING id INTO v_op_id;

 INSERT INTO private.financial_2c2_write_intents(
   organization_id,venta_id,tx_id,operation_id,request_id,
   monto,metodo,fecha,saldo_despues,etapa,pago_id
 ) VALUES(
   p_organization_id,p_venta_id,pg_catalog.pg_current_xact_id(),
   v_op_id,p_request_id,v_payment.monto,'reverso_transferencia',
   p_efectivo_at,v_after,'update_sale',v_payment.id
 );
 INSERT INTO public.venta_eventos_financieros(
   organization_id,venta_id,operacion_id,secuencia,tipo,
   delta_exigible,delta_cobros,efectivo_at,pago_id,reversa_evento_id
 ) VALUES(
   p_organization_id,p_venta_id,v_op_id,v_seq,'reverso',
   0,-v_payment.monto,p_efectivo_at,v_payment.id,v_origin.id
 ) RETURNING id INTO v_event;

 UPDATE public.venta_cuentas_financieras
 SET cobros_netos=0,saldo_pendiente=v_after,revision=revision+1,
     actualizado_at=v_now
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;
 UPDATE public.ventas SET saldo=v_after,estado='pendiente'
 WHERE organization_id=p_organization_id AND id=p_venta_id;

 UPDATE public.venta_cronogramas SET estado='sustituido' WHERE id=v_old.id
   AND organization_id=p_organization_id AND venta_id=p_venta_id;
 INSERT INTO public.venta_cronogramas(
  organization_id,venta_id,version,estado,origen_evento_id,creado_por
 ) VALUES(p_organization_id,p_venta_id,2,'vigente',v_event,v_actor)
 RETURNING id INTO v_new_id;
 INSERT INTO public.venta_cuotas(
  organization_id,venta_id,cronograma_id,numero,obligacion_id,
  vencimiento,es_legado,importe_original,importe_vigente
 )
 SELECT p_organization_id,p_venta_id,v_new_id,c.numero,c.obligacion_id,
     c.vencimiento,false,c.importe_original,c.importe_vigente
 FROM public.venta_cuotas c
 WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
   AND c.cronograma_id=v_old.id
 ORDER BY c.numero;
 INSERT INTO public.venta_cuotas(
   organization_id,venta_id,cronograma_id,numero,vencimiento,
   es_legado,importe_original,importe_vigente
 ) VALUES(p_organization_id,p_venta_id,v_new_id,v_last_number+1,v_last_date,
          false,v_payment.monto,v_payment.monto);

 IF (SELECT COALESCE(SUM(c.importe_vigente),0) FROM public.venta_cuotas c
    WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
      AND c.cronograma_id=v_new_id) IS DISTINCT FROM v_after
    OR NOT EXISTS(SELECT 1 FROM private.financial_2c_audit_sale(
         p_organization_id,p_venta_id) a WHERE a.apta_para_motor
         AND a.saldo_calculado=v_after AND a.revision=v_account.revision+1) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Reverso y cronograma v2 no conciliaron';
 END IF;
 DELETE FROM private.financial_2c2_write_intents
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tx_id=pg_catalog.pg_current_xact_id();
 v_result:=jsonb_build_object(
  'success',true,'idempotent',false,'venta_id',p_venta_id,
  'request_id',p_request_id,'original_event_id',v_origin.id,
  'reversal_event_id',v_event,'payment_id',v_payment.id,
  'bank_reversal_ref',p_bank_reversal_ref,'bank_evidence_id',v_bank_evidence,
  'schedule_version',2,'schedule_id',v_new_id,
  'previous_schedule_id',v_old.id,'amount',v_payment.monto,
  'balance',v_after,'revision',v_account.revision+1
 );
 UPDATE public.venta_operaciones_financieras SET
  resultado='aplicado',resultado_payload=v_result,
  actualizado_at=v_now
 WHERE id=v_op_id AND organization_id=p_organization_id
   AND venta_id=p_venta_id;
 INSERT INTO private.financial_2df_bank_evidence_usages(
 evidence_id,organization_id,venta_id,request_id,operacion_id,evento_id
 ) VALUES(v_bank_evidence,p_organization_id,p_venta_id,p_request_id,v_op_id,v_event);
 IF private.financial_2dc_supported_v2_schedule(p_organization_id,p_venta_id,v_new_id)
   IS NOT TRUE THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Origen del nuevo cronograma no certificado';
 END IF;
 RETURN v_result;
END;
$body$;
REVOKE ALL ON FUNCTION private.financial_2dc_reverse_initial_transfer(uuid,bigint,uuid,uuid,timestamptz,text) FROM PUBLIC,anon,authenticated,service_role;

-- Advisor: this INVOKER trigger uses only pg_catalog built-ins and must not
-- inherit caller-controlled search_path. Preserve its original behavior.
ALTER FUNCTION public.fn_autoclasificar_tipo_doc_cliente()
 SET search_path = '';
