-- 2C6B: internal atomic fiscal transition context, never client writable.
CREATE TABLE private.financial_nc_intents (
 organization_id uuid NOT NULL, venta_id bigint NOT NULL, nota_credito_id uuid NOT NULL,
 tx_id xid8 NOT NULL, etapa text NOT NULL DEFAULT 'fiscal' CHECK(etapa IN ('fiscal','ledger')),
 PRIMARY KEY(organization_id,venta_id,nota_credito_id,tx_id),
 FOREIGN KEY(organization_id,venta_id,nota_credito_id)
 REFERENCES public.notas_credito(organization_id,venta_id,id) ON DELETE RESTRICT
);
ALTER TABLE private.financial_nc_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.financial_nc_intents FROM PUBLIC,anon,authenticated,service_role;

CREATE TABLE private.financial_nc_quota_changes (
 organization_id uuid NOT NULL, venta_id bigint NOT NULL, evento_id uuid NOT NULL,
 cuota_id uuid NOT NULL, fase text NOT NULL CHECK(fase IN ('pendiente','liberado')), reduccion numeric(14,2) NOT NULL CHECK(reduccion>0),
 liberado numeric(14,2) NOT NULL CHECK(liberado>=0 AND liberado<=reduccion),
 PRIMARY KEY(organization_id,venta_id,evento_id,cuota_id,fase),
 FOREIGN KEY(organization_id,venta_id,evento_id) REFERENCES public.venta_eventos_financieros(organization_id,venta_id,id),
 FOREIGN KEY(organization_id,venta_id,cuota_id) REFERENCES public.venta_cuotas(organization_id,venta_id,id)
);
CREATE INDEX financial_nc_changes_quota ON private.financial_nc_quota_changes(organization_id,venta_id,cuota_id);
ALTER TABLE private.financial_nc_quota_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.financial_nc_quota_changes FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER financial_nc_changes_immutable BEFORE UPDATE OR DELETE ON private.financial_nc_quota_changes
FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();
CREATE UNIQUE INDEX financial_nc_one_acceptance ON public.venta_eventos_financieros(organization_id,venta_id,nota_credito_id)
 WHERE tipo='nota_credito';
CREATE UNIQUE INDEX financial_nc_one_reversal ON public.venta_eventos_financieros(organization_id,venta_id,nota_credito_id)
 WHERE tipo='reversion_ajuste' AND nota_credito_id IS NOT NULL;

CREATE FUNCTION private.financial_nc_apply_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' SET "TimeZone"='UTC' AS $engine$
DECLARE
 a public.venta_cuentas_financieras%ROWTYPE;
 old_amount numeric; new_amount numeric; delta numeric; prior numeric;
 op uuid; ev uuid; origin uuid; seq bigint; remaining numeric; piece numeric; release numeric;
 schedule uuid; q record; change record; audit record;
 e numeric; c numeric; d numeric; f numeric; due numeric;
BEGIN
 SELECT * INTO a FROM public.venta_cuentas_financieras
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id FOR UPDATE;
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.financial_nc_intents i WHERE i.organization_id=NEW.organization_id
 AND i.venta_id=NEW.venta_id AND i.nota_credito_id=NEW.id AND i.tx_id=pg_catalog.pg_current_xact_id()) THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Missing fiscal transaction intent'; END IF;
 old_amount:=CASE WHEN OLD.estado='aceptado' AND OLD.afecta_dinero AND OLD.estado_baja_tributaria<>'aceptada' THEN OLD.total ELSE 0 END;
 new_amount:=CASE WHEN NEW.estado='aceptado' AND NEW.afecta_dinero AND NEW.estado_baja_tributaria<>'aceptada' THEN NEW.total ELSE 0 END;
 delta:=old_amount-new_amount;
 IF delta=0 THEN RETURN NEW; END IF;
 IF NEW.moneda<>'PEN' OR a.moneda<>'PEN' OR a.estado_conciliacion<>'conciliada'
 OR NEW.total<=0 OR NEW.total>999999999999.99 OR NEW.total<>round(NEW.total,2)
 OR NEW.aceptado_at IS NULL OR NOT isfinite(NEW.aceptado_at) OR NEW.aceptado_at>clock_timestamp()
 OR (delta>0 AND (NEW.baja_aceptada_at IS NULL OR NOT isfinite(NEW.baja_aceptada_at) OR NEW.baja_aceptada_at<NEW.aceptado_at OR NEW.baja_aceptada_at>clock_timestamp())) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unreconciled fiscal transition'; END IF;
 SELECT coalesce(sum(delta_exigible),0) INTO prior FROM public.venta_eventos_financieros
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id;
 IF prior IS DISTINCT FROM -old_amount THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit note history not reconciled'; END IF;
 SELECT * INTO audit FROM private.financial_2c_audit_sale(NEW.organization_id,NEW.venta_id);
 IF cardinality(array_remove(audit.bloqueos,'nc_pendiente_motor_canonico'))<>0 THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Account failed pre-transition audit'; END IF;
 e:=a.exigible+delta; c:=a.cobros_netos; d:=greatest(e-c,0); f:=greatest(c-e,0);
 IF e<0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit notes exceed original obligation'; END IF;
 SELECT id INTO schedule FROM public.venta_cronogramas WHERE organization_id=NEW.organization_id
 AND venta_id=NEW.venta_id AND estado='vigente' AND version=1 FOR UPDATE;
 IF schedule IS NULL AND EXISTS(SELECT 1 FROM public.venta_cronogramas WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unsupported schedule version'; END IF;
 IF schedule IS NOT NULL THEN
 IF EXISTS(SELECT 1 FROM public.venta_cuotas cq WHERE cq.organization_id=NEW.organization_id AND cq.venta_id=NEW.venta_id AND cq.cronograma_id=schedule AND (cq.es_legado OR cq.vencimiento IS NULL))
 OR (SELECT sum(importe_vigente) FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)) IS DISTINCT FROM a.exigible
 OR EXISTS(SELECT 1 FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL) iq WHERE iq.importe_cobrado<0 OR iq.saldo_pendiente<0)
 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Invalid schedule obligations'; END IF;
 SELECT sum(saldo_pendiente) INTO due FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF due IS DISTINCT FROM a.saldo_pendiente THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Installments fail reconciliation'; END IF;
 END IF;
 SELECT coalesce(max(secuencia),0)+1 INTO seq FROM public.venta_eventos_financieros
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id;
 IF delta>0 THEN SELECT id INTO origin FROM public.venta_eventos_financieros WHERE organization_id=NEW.organization_id
 AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tipo='nota_credito';
 IF origin IS NULL THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Missing original adjustment'; END IF; END IF;
 INSERT INTO public.venta_operaciones_financieras(organization_id,venta_id,tipo,request_id,payload_hash,resultado)
 VALUES(NEW.organization_id,NEW.venta_id,CASE WHEN delta<0 THEN 'nota_credito' ELSE 'reversion_ajuste' END,
 NEW.id,md5(NEW.id::text||':'||delta::text),'aplicado') RETURNING id INTO op;
 INSERT INTO public.venta_eventos_financieros(organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at,nota_credito_id,reversa_evento_id)
 VALUES(NEW.organization_id,NEW.venta_id,op,seq,CASE WHEN delta<0 THEN 'nota_credito' ELSE 'reversion_ajuste' END,
 delta,0,CASE WHEN delta<0 THEN NEW.aceptado_at ELSE coalesce(NEW.baja_aceptada_at,now()) END,NEW.id,origin) RETURNING id INTO ev;
 IF schedule IS NOT NULL AND delta<0 THEN
 remaining:=-delta;
 -- First unpaid balances, then paid allocations, in reverse due-date order.
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento DESC,numero DESC LOOP
 IF q.saldo_pendiente<0 OR q.importe_cobrado<0 THEN RAISE EXCEPTION 'Invalid installment'; END IF;
 piece:=least(remaining,q.saldo_pendiente);
 IF piece>0 THEN
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente-piece WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=q.cuota_id;
 INSERT INTO private.financial_nc_quota_changes VALUES(NEW.organization_id,NEW.venta_id,ev,q.cuota_id,'pendiente',piece,0);
 remaining:=remaining-piece; END IF;
 END LOOP;
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento DESC,numero DESC LOOP
 piece:=least(remaining,q.importe_cobrado);
 IF piece>0 THEN
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente-piece WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=q.cuota_id;
 -- A quota used in the unpaid pass cannot be used here unless it is now fully paid;
 -- combine records before insertion by retaining separate event-level reduction rows.
 INSERT INTO public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado)
 VALUES(NEW.organization_id,NEW.venta_id,q.cuota_id,ev,'liberacion_nc',-piece);
 INSERT INTO private.financial_nc_quota_changes VALUES(NEW.organization_id,NEW.venta_id,ev,q.cuota_id,'liberado',piece,piece);
 remaining:=remaining-piece; END IF;
 END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='NC exceeds scheduled obligations'; END IF;
 ELSIF schedule IS NOT NULL AND delta>0 THEN
 FOR change IN SELECT * FROM private.financial_nc_quota_changes WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND evento_id=origin LOOP
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente+change.reduccion WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=change.cuota_id;
 END LOOP;
 -- A later NC may have released more cash. Reassign the currently available
 -- collected money, not a stale snapshot of allocations from this NC.
 SELECT least(c,e)-coalesce(sum(importe_cobrado),0) INTO remaining
 FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF remaining<0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Invalid compensated allocations'; END IF;
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento,numero LOOP
 piece:=least(remaining,q.saldo_pendiente);
 IF piece>0 THEN
 INSERT INTO public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado)
 VALUES(NEW.organization_id,NEW.venta_id,q.cuota_id,ev,'ajuste',piece);
 remaining:=remaining-piece;
 END IF; END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Incomplete compensated allocations'; END IF;
 END IF;
 UPDATE public.venta_cuentas_financieras SET exigible=e,saldo_pendiente=d,excedente=f,revision=revision+1,actualizado_at=clock_timestamp()
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id;
 UPDATE private.financial_nc_intents SET etapa='ledger' WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tx_id=pg_catalog.pg_current_xact_id();
 UPDATE public.ventas SET saldo=d,estado=CASE WHEN d=0 THEN 'pagado' ELSE 'pendiente' END WHERE organization_id=NEW.organization_id AND id=NEW.venta_id;
 UPDATE private.financial_nc_intents SET etapa='fiscal' WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tx_id=pg_catalog.pg_current_xact_id();
 IF schedule IS NOT NULL THEN
 SELECT sum(saldo_pendiente) INTO due FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF due IS DISTINCT FROM d THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Post-transition installments mismatch'; END IF;
 END IF;
 SELECT * INTO audit FROM private.financial_2c_audit_sale(NEW.organization_id,NEW.venta_id);
 IF cardinality(array_remove(audit.bloqueos,'nc_pendiente_motor_canonico'))<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Post-transition canonical audit failed'; END IF;
 RETURN NEW;
END $engine$;
REVOKE ALL ON FUNCTION private.financial_nc_apply_transition() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER zz_financial_nc_transition AFTER UPDATE ON public.notas_credito
FOR EACH ROW EXECUTE FUNCTION private.financial_nc_apply_transition();

CREATE OR REPLACE FUNCTION private.financial_2b_guard_legacy_financial_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    IF EXISTS (SELECT 1 FROM private.financial_nc_intents i
      WHERE i.organization_id=v_new_org AND i.venta_id=v_new_sale
        AND i.tx_id=pg_catalog.pg_current_xact_id()) THEN
      IF TG_TABLE_NAME='notas_credito' AND TG_OP='UPDATE' THEN
      IF EXISTS (
        SELECT 1 FROM private.financial_nc_intents i WHERE i.organization_id=v_new_org
          AND i.venta_id=v_new_sale AND i.nota_credito_id=NEW.id
          AND i.tx_id=pg_catalog.pg_current_xact_id())
        AND NEW.total IS NOT DISTINCT FROM OLD.total
        AND NEW.moneda IS NOT DISTINCT FROM OLD.moneda
        AND NEW.afecta_dinero IS NOT DISTINCT FROM OLD.afecta_dinero
        AND NEW.comprobante_id IS NOT DISTINCT FROM OLD.comprobante_id
        AND NEW.id=OLD.id THEN RETURN NEW; END IF;
      END IF;
      IF TG_TABLE_NAME='ventas' AND TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-'monto_notas_credito'-'estado_tributario')=
           (to_jsonb(OLD)-'monto_notas_credito'-'estado_tributario') THEN RETURN NEW; END IF;
        IF (to_jsonb(NEW)-'saldo'-'estado')=(to_jsonb(OLD)-'saldo'-'estado')
          AND EXISTS(SELECT 1 FROM private.financial_nc_intents i
          JOIN public.venta_cuentas_financieras cf USING(organization_id,venta_id)
          WHERE i.organization_id=v_new_org AND i.venta_id=v_new_sale
            AND i.tx_id=pg_catalog.pg_current_xact_id() AND i.etapa='ledger'
            AND NEW.saldo=cf.saldo_pendiente
            AND NEW.estado=CASE WHEN cf.saldo_pendiente=0 THEN 'pagado' ELSE 'pendiente' END)
        THEN RETURN NEW; END IF;
      END IF;
    END IF;

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
             AND (
                (v_intent.metodo IN ('efectivo','transferencia')
                 AND ev.tipo='cobro'
                 AND ev.delta_cobros=v_intent.monto)
                OR
                (v_intent.metodo='reverso_transferencia'
                 AND ev.tipo='reverso'
                 AND ev.delta_exigible=0
                 AND ev.delta_cobros=-v_intent.monto
                 AND EXISTS (
                   SELECT 1 FROM public.venta_eventos_financieros origin
                   JOIN public.pagos_venta payment
                     ON payment.organization_id=origin.organization_id
                    AND payment.venta_id=origin.venta_id
                    AND payment.id=origin.pago_id
                   WHERE origin.organization_id=ev.organization_id
                     AND origin.venta_id=ev.venta_id
                     AND origin.id=ev.reversa_evento_id
                     AND origin.tipo='cobro'
                     AND origin.pago_id=v_intent.pago_id
                     AND origin.delta_cobros=v_intent.monto
                     AND lower(btrim(payment.metodo))='transferencia'
                     AND payment.cash_session_id IS NULL
                     AND payment.cash_register_id IS NULL
                 ))
             )
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
$function$
;
CREATE OR REPLACE FUNCTION public.nota_credito_finalizar(p_nota_credito_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_nota record;
  v_lock_sale_id bigint;
  v_estado text := LOWER(TRIM(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_stock_result jsonb;
  v_total_nc numeric(14,2);
  v_venta_total numeric(14,2);
BEGIN
  IF v_estado NOT IN ('aceptado', 'rechazado', 'pendiente_reintento', 'resultado_incierto') THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  -- 2C6B2: serialize fiscal finalizers within a tenant before row locks.
  -- The future canonical NC writer must acquire this same gate first.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(private.require_service_organization_id()::text
      || ':financial-fiscal-transition',0));

  SELECT venta_id INTO v_lock_sale_id FROM public.notas_credito
  WHERE organization_id=private.require_service_organization_id() AND id=p_nota_credito_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Nota de crédito no encontrada'; END IF;
  PERFORM 1 FROM public.venta_cuentas_financieras
  WHERE organization_id=private.require_service_organization_id() AND venta_id=v_lock_sale_id
  FOR UPDATE;
  PERFORM 1 FROM public.ventas
  WHERE organization_id=private.require_service_organization_id() AND id=v_lock_sale_id
  FOR UPDATE;

  SELECT * INTO v_nota
  FROM public.notas_credito
  WHERE organization_id = private.require_service_organization_id()
    AND id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.venta_id IS DISTINCT FROM v_lock_sale_id THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='NC cambio de venta durante bloqueo; reintentar';
  END IF;

  IF v_nota.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object(
      'success', true, 'estado', 'aceptado', 'idempotent', true,
      'ignored_state', v_estado, 'nota_credito_id', p_nota_credito_id
    );
  END IF;

  IF v_nota.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_nota.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object(
        'success', true, 'estado', 'aceptado', 'idempotent', true,
        'nota_credito_id', p_nota_credito_id
      );
    END IF;
    RAISE EXCEPTION 'El bloqueo de la nota ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(TRIM(p_resultado->>'mensaje_error'), '');

  INSERT INTO private.financial_nc_intents(organization_id,venta_id,nota_credito_id,tx_id)
  SELECT cf.organization_id,cf.venta_id,p_nota_credito_id,pg_catalog.pg_current_xact_id()
  FROM public.venta_cuentas_financieras cf WHERE cf.organization_id=v_nota.organization_id
    AND cf.venta_id=v_nota.venta_id;

  UPDATE public.notas_credito
  SET
    estado = v_estado,
    payload_json = COALESCE(p_resultado->'payload_json', payload_json),
    respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
    xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
    cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
    pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
    hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
    codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
    descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
    observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
    archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
    ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
    ultimo_error_tipo = CASE
      WHEN v_estado = 'aceptado' THEN NULL
      ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo)
    END,
    ultimo_http_status = v_codigo_http,
    enviado_at = CASE
      WHEN v_estado IN ('aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now())
      ELSE enviado_at
    END,
    aceptado_at = CASE
      WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, clock_timestamp())
      ELSE aceptado_at
    END,
    pdf_generado_at = CASE
      WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL THEN now()
      ELSE pdf_generado_at
    END,
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
  WHERE id = p_nota_credito_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.notas_credito_intentos
    SET
      resultado = v_estado,
      codigo_http = v_codigo_http,
      codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
      mensaje_error = v_mensaje,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      fecha_fin = now(),
      duracion_ms = COALESCE(
        v_duracion,
        GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (now() - fecha_inicio)) * 1000)::integer)
      )
    WHERE id = v_intento_id;
  END IF;

  IF v_estado = 'aceptado'
     AND v_nota.reponer_stock = true
     AND v_nota.stock_aplicado = false THEN
    v_stock_result := public._aplicar_stock_nota_credito(p_nota_credito_id);
  END IF;

  SELECT
    COALESCE(SUM(nc.total), 0),
    v.total
  INTO v_total_nc, v_venta_total
  FROM public.ventas AS v
  LEFT JOIN public.notas_credito AS nc
    ON nc.venta_id = v.id
   AND nc.estado = 'aceptado'
   AND nc.afecta_dinero = true
   AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
  WHERE v.id = v_nota.venta_id
  GROUP BY v.total;

  UPDATE public.ventas
  SET
    monto_notas_credito = ROUND(COALESCE(v_total_nc, 0), 2),
    estado_tributario = CASE
      WHEN COALESCE(v_total_nc, 0) >= COALESCE(v_venta_total, 0) - 0.02 THEN 'anulada'
      WHEN COALESCE(v_total_nc, 0) > 0.01 THEN 'parcialmente_ajustada'
      ELSE 'vigente'
    END
  WHERE id = v_nota.venta_id;

  IF EXISTS(SELECT 1 FROM private.financial_2c_audit_sale(v_nota.organization_id,v_nota.venta_id) a WHERE a.estado_conciliacion<>'ausente' AND NOT a.apta_para_motor) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Final NC audit failed'; END IF;
  DELETE FROM private.financial_nc_intents WHERE tx_id=pg_catalog.pg_current_xact_id() AND nota_credito_id=p_nota_credito_id;

  RETURN jsonb_build_object(
    'success', true,
    'estado', v_estado,
    'nota_credito_id', p_nota_credito_id,
    'venta_id', v_nota.venta_id,
    'stock_aplicado', CASE
      WHEN v_estado = 'aceptado' THEN (
        SELECT stock_aplicado FROM public.notas_credito
        WHERE id = p_nota_credito_id
      )
      ELSE false
    END,
    'stock_resultado', v_stock_result,
    'stock_error', (
      SELECT stock_error FROM public.notas_credito
      WHERE id = p_nota_credito_id
    )
  );
END;
$function$
;
CREATE OR REPLACE FUNCTION public.tributario_finalizar_proceso(p_proceso_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_proceso record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_det record;
  v_stock_result jsonb;
BEGIN
  IF v_estado NOT IN (
    'ticket_pendiente', 'aceptado', 'rechazado',
    'pendiente_reintento', 'resultado_incierto'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  -- 2C6B2: serialize fiscal finalizers within a tenant before row locks.
  -- The future canonical NC writer must acquire this same gate first.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(private.require_service_organization_id()::text
      || ':financial-fiscal-transition',0));

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE organization_id = private.require_service_organization_id()
    AND id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado, 'proceso_id', p_proceso_id);
  END IF;

  IF v_proceso.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_proceso.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'proceso_id', p_proceso_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del proceso ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  -- Lock all affected accounts/sales in stable order before updating documents.
  PERFORM cf.venta_id FROM public.venta_cuentas_financieras cf
  WHERE cf.organization_id=private.require_service_organization_id()
    AND cf.venta_id IN (SELECT s.venta_id FROM public.solicitudes_baja_tributaria s
      WHERE s.organization_id=cf.organization_id AND s.proceso_id=p_proceso_id)
  ORDER BY cf.venta_id FOR UPDATE;
  PERFORM v.id FROM public.ventas v
  WHERE v.organization_id=private.require_service_organization_id()
    AND v.id IN (SELECT s.venta_id FROM public.solicitudes_baja_tributaria s
      WHERE s.organization_id=v.organization_id AND s.proceso_id=p_proceso_id)
  ORDER BY v.id FOR UPDATE;
  INSERT INTO private.financial_nc_intents(organization_id,venta_id,nota_credito_id,tx_id)
  SELECT DISTINCT cf.organization_id,cf.venta_id,s.nota_credito_id,pg_catalog.pg_current_xact_id()
  FROM public.solicitudes_baja_tributaria s JOIN public.venta_cuentas_financieras cf
    ON cf.organization_id=s.organization_id AND cf.venta_id=s.venta_id
  WHERE s.organization_id=private.require_service_organization_id()
    AND s.proceso_id=p_proceso_id AND s.nota_credito_id IS NOT NULL;

  UPDATE public.procesos_tributarios
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_proceso_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.procesos_tributarios_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.solicitudes_baja_tributaria
  SET estado = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE estado END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END
  WHERE proceso_id = p_proceso_id;

  UPDATE public.comprobantes_electronicos ce
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE ce.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(ce.baja_aceptada_at, now()) ELSE ce.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.comprobante_id = ce.id;

  UPDATE public.notas_credito nc
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE nc.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(nc.baja_aceptada_at, clock_timestamp()) ELSE nc.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.nota_credito_id = nc.id;

  IF v_estado = 'aceptado' THEN
    UPDATE public.ventas v
    SET estado_tributario = 'baja_tributaria'
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_proceso_id
      AND s.tipo_origen = 'comprobante'
      AND s.venta_id = v.id;

    FOR v_det IN
      SELECT DISTINCT d.nota_credito_id, d.venta_id
      FROM public.procesos_tributarios_detalles d
      WHERE d.proceso_id = p_proceso_id AND d.nota_credito_id IS NOT NULL
    LOOP
      v_stock_result := public._revertir_stock_nota_credito_por_baja(v_det.nota_credito_id);
      PERFORM public.recalcular_estado_tributario_venta(v_det.venta_id);
    END LOOP;
  END IF;

  IF EXISTS(SELECT 1 FROM private.financial_nc_intents i CROSS JOIN LATERAL private.financial_2c_audit_sale(i.organization_id,i.venta_id) a WHERE i.tx_id=pg_catalog.pg_current_xact_id() AND i.organization_id=private.require_service_organization_id() AND NOT a.apta_para_motor) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Final fiscal batch audit failed'; END IF;
  DELETE FROM private.financial_nc_intents WHERE tx_id=pg_catalog.pg_current_xact_id() AND organization_id=private.require_service_organization_id();
  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'proceso_id', p_proceso_id, 'stock_resultado', v_stock_result);
END;
$function$
;
CREATE OR REPLACE FUNCTION private.financial_2c_audit_sale(p_organization_id uuid, p_venta_id bigint)
 RETURNS TABLE(organization_id uuid, venta_id bigint, moneda text, exigible_eventos numeric, cobros_eventos numeric, saldo_calculado numeric, excedente_calculado numeric, estado_conciliacion text, revision bigint, apta_para_motor boolean, bloqueos text[])
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_account public.venta_cuentas_financieras%ROWTYPE;
  v_sale public.ventas%ROWTYPE;
  v_e numeric;
  v_c numeric;
  v_count bigint;
  v_min_seq bigint;
  v_max_seq bigint;
  v_payment_events bigint;
  v_distinct_payment_events bigint;
  v_payment_sum numeric;
  v_payment_count bigint;
  v_nc_count bigint;
  v_coverage text;
  v_blockers text[] := ARRAY[]::text[];
BEGIN
  IF p_organization_id IS NULL OR p_venta_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Organización y venta requeridas';
  END IF;

  SELECT * INTO v_account
  FROM public.venta_cuentas_financieras cf
  WHERE cf.organization_id=p_organization_id AND cf.venta_id=p_venta_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT p_organization_id,p_venta_id,NULL::text,
       NULL::numeric,NULL::numeric,NULL::numeric,NULL::numeric,
       'ausente'::text, NULL::bigint,false,ARRAY['cuenta_no_abierta']::text[];
    RETURN;
  END IF;

  SELECT * INTO v_sale FROM public.ventas v
  WHERE v.organization_id=p_organization_id AND v.id=p_venta_id;

  SELECT COALESCE(SUM(ev.delta_exigible),0),COALESCE(SUM(ev.delta_cobros),0),
         COUNT(*),MIN(ev.secuencia),MAX(ev.secuencia),
         COUNT(*) FILTER (WHERE ev.tipo='cobro'),
         COUNT(DISTINCT ev.pago_id) FILTER (WHERE ev.tipo='cobro')
    INTO v_e,v_c,v_count,v_min_seq,v_max_seq,
         v_payment_events,v_distinct_payment_events
    FROM public.venta_eventos_financieros ev
    WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id;

  SELECT COALESCE(SUM(pv.monto),0),COUNT(*)
    INTO v_payment_sum,v_payment_count
    FROM public.pagos_venta pv
    WHERE pv.organization_id=p_organization_id AND pv.venta_id=p_venta_id;

  SELECT COUNT(*) INTO v_nc_count
    FROM public.notas_credito nc
    WHERE nc.organization_id=p_organization_id AND nc.venta_id=p_venta_id
      AND (coalesce((SELECT sum(ev.delta_exigible) FROM public.venta_eventos_financieros ev
        WHERE ev.organization_id=nc.organization_id AND ev.venta_id=nc.venta_id AND ev.nota_credito_id=nc.id),0)
        IS DISTINCT FROM CASE WHEN nc.estado='aceptado' AND nc.afecta_dinero
          AND nc.estado_baja_tributaria<>'aceptada' THEN -nc.total ELSE 0 END);

  SELECT op.metadata_apertura->>'cobertura' INTO v_coverage
  FROM public.venta_operaciones_financieras op
  WHERE op.organization_id=p_organization_id
    AND op.venta_id=p_venta_id AND op.tipo='apertura'
    AND op.resultado='aplicado'
  ORDER BY op.creado_at,op.id LIMIT 1;

  IF v_account.estado_conciliacion<>'conciliada' THEN
    v_blockers:=array_append(v_blockers,'cuenta_no_conciliada');
  END IF;
  IF v_coverage IS DISTINCT FROM 'historico_auditado' THEN
    v_blockers:=array_append(v_blockers,'cobertura_historica_no_certificada');
  END IF;
  IF v_count=0 OR v_min_seq IS DISTINCT FROM 1 OR v_max_seq<>v_count THEN
    v_blockers:=array_append(v_blockers,'secuencia_eventos_incompleta');
  END IF;
  IF v_e<0 OR v_c<0 OR v_e<>ROUND(v_e,2) OR v_c<>ROUND(v_c,2) THEN
    v_blockers:=array_append(v_blockers,'importes_eventos_invalidos');
  END IF;
  IF v_account.exigible<>v_e OR v_account.cobros_netos<>v_c
     OR v_account.saldo_pendiente<>GREATEST(v_e-v_c,0)
     OR v_account.excedente<>GREATEST(v_c-v_e,0) THEN
    v_blockers:=array_append(v_blockers,'proyeccion_no_coincide_eventos');
  END IF;
  -- Cobros brutos se mantienen en pagos_venta. Cada reverso debe ser
  -- negativo, íntegro, único y vinculado al cobro y al pago originales.
  IF v_payment_count<>v_payment_events
     OR v_payment_events<>v_distinct_payment_events
     OR v_payment_sum + COALESCE((
       SELECT SUM(ev.delta_cobros)
       FROM public.venta_eventos_financieros ev
       WHERE ev.organization_id=p_organization_id
         AND ev.venta_id=p_venta_id AND ev.tipo='reverso'
     ),0)<>v_c
     OR EXISTS (
       SELECT 1
       FROM public.venta_eventos_financieros rv
       LEFT JOIN public.venta_eventos_financieros original
         ON original.organization_id=rv.organization_id
        AND original.venta_id=rv.venta_id AND original.id=rv.reversa_evento_id
       LEFT JOIN public.pagos_venta p
         ON p.organization_id=rv.organization_id
        AND p.venta_id=rv.venta_id AND p.id=rv.pago_id
       WHERE rv.organization_id=p_organization_id
         AND rv.venta_id=p_venta_id AND rv.tipo='reverso'
         AND (rv.delta_exigible<>0 OR rv.delta_cobros>=0
              OR original.id IS NULL OR original.tipo<>'cobro'
              OR original.pago_id IS DISTINCT FROM rv.pago_id
              OR rv.delta_cobros IS DISTINCT FROM -original.delta_cobros
              OR p.id IS NULL
              OR lower(btrim(p.metodo))<>'transferencia'
              OR p.cash_session_id IS NOT NULL OR p.cash_register_id IS NOT NULL)
     )
     OR EXISTS (
       SELECT 1 FROM public.pagos_venta pv
       LEFT JOIN public.venta_eventos_financieros ev
         ON ev.organization_id=pv.organization_id
        AND ev.venta_id=pv.venta_id AND ev.pago_id=pv.id AND ev.tipo='cobro'
       WHERE pv.organization_id=p_organization_id AND pv.venta_id=p_venta_id
         AND (ev.id IS NULL OR ev.delta_cobros IS DISTINCT FROM pv.monto)
     )
     OR EXISTS (
       SELECT 1 FROM public.venta_eventos_financieros ev
       WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id
         AND ev.tipo='cobro' AND ev.pago_id IS NULL
     ) THEN
    v_blockers:=array_append(v_blockers,'origenes_pago_no_conciliados');
  END IF;
  IF v_nc_count>0 THEN
    v_blockers:=array_append(v_blockers,'nc_pendiente_motor_canonico');
  END IF;
  IF v_sale.id IS NULL OR v_sale.saldo IS DISTINCT FROM GREATEST(v_e-v_c,0) THEN
    v_blockers:=array_append(v_blockers,'saldo_venta_legacy_divergente');
  END IF;

  RETURN QUERY SELECT p_organization_id,p_venta_id,v_account.moneda,
    v_e,v_c,GREATEST(v_e-v_c,0),GREATEST(v_c-v_e,0),
    v_account.estado_conciliacion,v_account.revision,
    cardinality(v_blockers)=0,v_blockers;
END;
$function$
;
CREATE OR REPLACE FUNCTION private.financial_2c4_allocate_cash_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_intent private.financial_2c2_write_intents%ROWTYPE;
 v_count integer;
 v_bad_count integer;
 v_min_number integer;
 v_max_number integer;
 v_due numeric;
 v_applied numeric;
 v_remaining numeric;
 v_room numeric;
 v_piece numeric;
 v_total_assigned numeric := 0;
 v_previous numeric;
 v_quota record;
BEGIN
 IF NEW.tipo<>'cobro' THEN
   RETURN NEW;
 END IF;

 -- Una venta sin historial de cuotas NO recibe vencimientos ficticios.
 SELECT cr.* INTO v_schedule
 FROM public.venta_cronogramas cr
 WHERE cr.organization_id=NEW.organization_id
   AND cr.venta_id=NEW.venta_id
   AND cr.estado='vigente'
 FOR UPDATE;
 IF NOT FOUND THEN
   IF EXISTS (
     SELECT 1 FROM public.venta_cronogramas cr
     WHERE cr.organization_id=NEW.organization_id
       AND cr.venta_id=NEW.venta_id
   ) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Hay cronogramas anteriores pero ninguno vigente';
   END IF;
   RETURN NEW;
 END IF;

 -- La versión 2 requiere reasignaciones históricas explícitas no incluidas
 -- aún en 2C4: no recontar movimientos de versiones sustituidas.
 IF v_schedule.version<>1 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma versionado requiere transferencia de asignaciones';
 END IF;

 -- Un cobro con cuotas solo puede proceder de uno de los dos escritores
 -- internos, ya que ellos crean esta intención privada antes del evento.
 SELECT i.* INTO v_intent
 FROM private.financial_2c2_write_intents i
 WHERE i.organization_id=NEW.organization_id
   AND i.venta_id=NEW.venta_id
   AND i.tx_id=pg_catalog.pg_current_xact_id()
   AND i.operation_id=NEW.operacion_id
   AND i.pago_id IS NULL
   AND i.etapa='insert_payment';
 IF NOT FOUND OR v_intent.monto IS DISTINCT FROM NEW.delta_cobros
    OR NEW.delta_exigible<>0 OR NEW.pago_id IS NULL
    OR NEW.delta_cobros<=0 OR NEW.delta_cobros<>round(NEW.delta_cobros,2) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Evento de cuota sin intención de cobro válida';
 END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=NEW.organization_id
   AND cf.venta_id=NEW.venta_id
 FOR UPDATE;
 IF NOT FOUND OR v_account.moneda<>'PEN'
   OR v_account.estado_conciliacion<>'conciliada'
   OR NEW.delta_cobros>v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera no elegible para asignar cobro a cuotas';
 END IF;

 -- Suma de obligaciones pendientes = saldo canónico previo al cobro.
 -- Solo se admiten movimientos positivos de cobro hasta disponer de
 -- reversos y NC (fase posterior).
 SELECT COUNT(*),MIN(c.numero),MAX(c.numero),
        COALESCE(SUM(c.importe_vigente),0),
        COUNT(*) FILTER (
          WHERE c.es_legado OR c.vencimiento IS NULL
             OR c.importe_vigente<0
             OR c.importe_vigente<>round(c.importe_vigente,2)
        )
 INTO v_count,v_min_number,v_max_number,v_due,v_bad_count
 FROM public.venta_cuotas c
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id
   AND c.cronograma_id=v_schedule.id;

 IF v_count=0 OR v_min_number<>1 OR v_max_number<>v_count
   OR v_bad_count>0 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma incompleto, legado o importes inválidos';
 END IF;

 SELECT COALESCE(SUM(m.importe_asignado),0) INTO v_applied
 FROM public.venta_cuota_movimientos m
 JOIN public.venta_cuotas c
   ON c.organization_id=m.organization_id
   AND c.venta_id=m.venta_id AND c.id=m.cuota_id
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id;

 IF v_applied<0 OR v_applied<>round(v_applied,2)
    OR v_due-v_applied IS DISTINCT FROM v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Saldo de cuotas no coincide con deuda canónica anterior al cobro';
 END IF;

 v_remaining:=NEW.delta_cobros;
 FOR v_quota IN
  SELECT c.id,c.numero,c.vencimiento,c.importe_vigente,
         COALESCE((
           SELECT SUM(m.importe_asignado)
           FROM public.venta_cuota_movimientos m
           WHERE m.organization_id=c.organization_id
             AND m.venta_id=c.venta_id AND m.cuota_id=c.id
         ),0) as asignado
  FROM public.venta_cuotas c
  WHERE c.organization_id=NEW.organization_id
    AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id
  ORDER BY c.vencimiento,c.numero
 LOOP
   IF v_remaining=0 THEN EXIT; END IF;
   v_room:=v_quota.importe_vigente-v_quota.asignado;
   IF v_room<0 OR v_room<>round(v_room,2) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Cuota excede su obligación vigente';
   END IF;
   v_piece:=LEAST(v_remaining,v_room);
   IF v_piece>0 THEN
     INSERT INTO public.venta_cuota_movimientos(
       organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado
     ) VALUES(
       NEW.organization_id,NEW.venta_id,v_quota.id,NEW.id,'cobro',v_piece
     );
     v_remaining:=v_remaining-v_piece;
     v_total_assigned:=v_total_assigned+v_piece;
   END IF;
 END LOOP;

 IF v_remaining<>0 OR v_total_assigned<>NEW.delta_cobros THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Asignación incompleta de cobro, rollback de transacción';
 END IF;
 RETURN NEW;
END;
$function$
;
