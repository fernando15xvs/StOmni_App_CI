-- 2C5B-B: private, evidence-backed refund accounting. No bank API dispatch.
ALTER TABLE private.venta_solicitudes_devolucion ADD CONSTRAINT refund_case_scope UNIQUE(organization_id,venta_id,id);
CREATE TABLE private.refund_reservations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, venta_id bigint NOT NULL,
 case_id uuid NOT NULL, amount numeric(14,2) NOT NULL CHECK(amount>0),
 state text NOT NULL CHECK(state IN ('held','released','paid')), actor_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(organization_id,venta_id,id),
 FOREIGN KEY(organization_id,venta_id,case_id) REFERENCES private.venta_solicitudes_devolucion(organization_id,venta_id,id)
);
CREATE UNIQUE INDEX refund_one_hold_per_case ON private.refund_reservations(organization_id,case_id) WHERE state='held';
CREATE INDEX refund_holds_sale ON private.refund_reservations(organization_id,venta_id) WHERE state='held';
CREATE TABLE private.refund_bank_accounts (
 id uuid NOT NULL, organization_id uuid NOT NULL REFERENCES public.organizations(id),
 currency text NOT NULL DEFAULT 'PEN' CHECK(currency='PEN'),
 balance numeric(14,2) NOT NULL CHECK(balance>=0), reconciled_at timestamptz NOT NULL,
 PRIMARY KEY(organization_id,id)
);
CREATE TABLE private.refund_commands (
 organization_id uuid NOT NULL REFERENCES public.organizations(id), request_id uuid NOT NULL,
 action text NOT NULL, fingerprint text NOT NULL, actor_id uuid NOT NULL, result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(organization_id,request_id)
);
CREATE TABLE private.refund_fund_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL,
 venta_id bigint, reservation_id uuid, event_id uuid,
 bank_id uuid, cash_session_id uuid, cash_register_id uuid,
 kind text NOT NULL CHECK(kind IN ('reconcile','payout','return')),
 delta numeric(14,2) NOT NULL, actor_id uuid NOT NULL,
 evidence_ref text NOT NULL CHECK(length(btrim(evidence_ref)) BETWEEN 5 AND 250),
 evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
 effective_at timestamptz NOT NULL CHECK(isfinite(effective_at)),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), reverses_id uuid,
 UNIQUE(organization_id,id), UNIQUE(organization_id,event_id), UNIQUE(organization_id,evidence_ref),
 FOREIGN KEY(organization_id,bank_id) REFERENCES private.refund_bank_accounts(organization_id,id),
 FOREIGN KEY(organization_id,cash_register_id,cash_session_id) REFERENCES public.sesiones_caja(organization_id,cash_register_id,id),
 FOREIGN KEY(organization_id,venta_id,reservation_id) REFERENCES private.refund_reservations(organization_id,venta_id,id),
 FOREIGN KEY(organization_id,venta_id,event_id) REFERENCES public.venta_eventos_financieros(organization_id,venta_id,id),
 FOREIGN KEY(organization_id,reverses_id) REFERENCES private.refund_fund_movements(organization_id,id),
 CHECK((bank_id IS NOT NULL AND cash_session_id IS NULL AND cash_register_id IS NULL) OR
       (bank_id IS NULL AND cash_session_id IS NOT NULL AND cash_register_id IS NOT NULL)),
 CHECK((kind='reconcile' AND bank_id IS NOT NULL AND venta_id IS NULL AND reservation_id IS NULL AND event_id IS NULL AND reverses_id IS NULL) OR
       (kind='payout' AND delta<0 AND venta_id IS NOT NULL AND reservation_id IS NOT NULL AND event_id IS NOT NULL AND reverses_id IS NULL) OR
       (kind='return' AND delta>0 AND venta_id IS NOT NULL AND reservation_id IS NOT NULL AND event_id IS NOT NULL AND reverses_id IS NOT NULL))
);
CREATE UNIQUE INDEX refund_one_payout ON private.refund_fund_movements(organization_id,reservation_id) WHERE kind='payout';
CREATE UNIQUE INDEX refund_one_return ON private.refund_fund_movements(organization_id,reverses_id) WHERE kind='return';
CREATE INDEX refund_fund_sale ON private.refund_fund_movements(organization_id,venta_id);
CREATE INDEX refund_fund_bank ON private.refund_fund_movements(organization_id,bank_id);
CREATE INDEX refund_fund_session ON private.refund_fund_movements(organization_id,cash_session_id);
CREATE TABLE private.refund_write_intents (
 organization_id uuid NOT NULL, venta_id bigint NOT NULL, tx_id xid8 NOT NULL,
 PRIMARY KEY(organization_id,venta_id,tx_id),
 FOREIGN KEY(organization_id,venta_id) REFERENCES public.venta_cuentas_financieras(organization_id,venta_id)
);
ALTER TABLE private.refund_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.refund_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.refund_commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.refund_fund_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.refund_write_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.refund_reservations,private.refund_bank_accounts,private.refund_commands,private.refund_fund_movements,private.refund_write_intents FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER refund_commands_immutable BEFORE UPDATE OR DELETE ON private.refund_commands FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();
CREATE TRIGGER refund_funds_immutable BEFORE UPDATE OR DELETE ON private.refund_fund_movements FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();

CREATE FUNCTION private.refund_protect_reserved_surplus() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $fn$
BEGIN
 IF NEW.excedente<(SELECT coalesce(sum(r.amount),0) FROM private.refund_reservations r
 WHERE r.organization_id=NEW.organization_id AND r.venta_id=NEW.venta_id AND r.state='held') THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Surplus reserved for refund; release reservation first'; END IF;
 RETURN NEW;
END $fn$;
REVOKE ALL ON FUNCTION private.refund_protect_reserved_surplus() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER refund_protect_reserved_surplus BEFORE UPDATE ON public.venta_cuentas_financieras FOR EACH ROW EXECUTE FUNCTION private.refund_protect_reserved_surplus();

CREATE FUNCTION private.financial_refund_command(p_org uuid,p_request uuid,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' SET "TimeZone"='UTC' AS $fn$
#variable_conflict use_variable
DECLARE
 actor uuid:=auth.uid(); fp text; result jsonb; existing private.refund_commands%ROWTYPE;
 account public.venta_cuentas_financieras%ROWTYPE; case_row private.venta_solicitudes_devolucion%ROWTYPE;
 reservation private.refund_reservations%ROWTYPE; original private.refund_fund_movements%ROWTYPE;
 bank private.refund_bank_accounts%ROWTYPE; session_row public.sesiones_caja%ROWTYPE;
 sale bigint; case_id uuid; reservation_id uuid; bank_id uuid; session_id uuid;
 amount numeric; available numeric; held numeric; already_paid numeric; new_c numeric; new_d numeric; new_f numeric;
 at_time timestamptz; evidence text; digest text; op uuid; ev uuid; movement uuid; seq bigint;
 q record; remaining numeric; piece numeric; audit record;
BEGIN
 IF p_org IS NULL OR p_request IS NULL OR actor IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
 OR p_action IS NULL OR p_action NOT IN ('bank_reconcile','reserve','release','settle','reverse') THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Refund command identity and payload required'; END IF;
 IF private.current_organization_id() IS DISTINCT FROM p_org OR NOT private.has_permission('tenant.admin') THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Active tenant administrator required'; END IF;
 fp:=encode(extensions.digest(jsonb_build_object('action',p_action,'payload',p_payload,'actor',actor)::text,'sha256'),'hex');
 -- Serialize request reuse even across sales. This gate is never acquired by other writers.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_org::text||':refund-request:'||p_request::text,0));
 SELECT * INTO existing FROM private.refund_commands rc WHERE rc.organization_id=p_org AND rc.request_id=p_request;
 IF FOUND THEN
 IF existing.fingerprint<>fp THEN RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Refund request reused with different payload'; END IF;
 RETURN existing.result||jsonb_build_object('idempotent',true); END IF;

 IF p_action IN ('bank_reconcile','settle','reverse') THEN
 at_time:=(p_payload->>'effective_at')::timestamptz; evidence:=btrim(p_payload->>'evidence_ref'); digest:=p_payload->>'evidence_sha256';
 IF at_time IS NULL OR NOT isfinite(at_time) OR at_time>clock_timestamp() OR evidence IS NULL OR length(evidence) NOT BETWEEN 5 AND 250 OR digest IS NULL OR digest !~ '^[0-9a-f]{64}$' THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Executed movement requires timestamp and documentary evidence'; END IF;
 END IF;
 IF p_action='bank_reconcile' THEN
 bank_id:=(p_payload->>'bank_id')::uuid;amount:=(p_payload->>'balance')::numeric;
 IF bank_id IS NULL OR amount IS NULL OR amount<0 OR amount>999999999999.99 OR amount<>round(amount,2) THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Valid PEN bank reconciliation required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_org::text||':refund-bank:'||bank_id::text,0));
 SELECT * INTO bank FROM private.refund_bank_accounts b WHERE b.organization_id=p_org AND b.id=bank_id FOR UPDATE;
 IF FOUND THEN
 IF at_time<bank.reconciled_at OR EXISTS(SELECT 1 FROM private.refund_fund_movements m WHERE m.organization_id=p_org AND m.bank_id=bank_id AND m.effective_at>at_time) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Stale bank reconciliation'; END IF;
 IF bank.balance IS DISTINCT FROM (SELECT coalesce(sum(fm.delta),0) FROM private.refund_fund_movements fm WHERE fm.organization_id=p_org AND fm.bank_id=bank_id) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Bank projection not reconciled with evidence ledger'; END IF;
 available:=bank.balance;
 ELSE available:=0;
 INSERT INTO private.refund_bank_accounts(id,organization_id,balance,reconciled_at) VALUES(bank_id,p_org,0,at_time);
 END IF;
 INSERT INTO private.refund_fund_movements(organization_id,bank_id,kind,delta,actor_id,evidence_ref,evidence_sha256,effective_at)
 VALUES(p_org,bank_id,'reconcile',amount-available,actor,evidence,digest,at_time) RETURNING id INTO movement;
 UPDATE private.refund_bank_accounts b SET balance=amount,reconciled_at=at_time WHERE b.organization_id=p_org AND b.id=bank_id;
 result:=jsonb_build_object('success',true,'bank_id',bank_id,'balance',amount,'movement_id',movement,'external_transfer_sent',false);
 ELSE
 IF p_action='reserve' THEN
 case_id:=(p_payload->>'case_id')::uuid; amount:=(p_payload->>'amount')::numeric;
 SELECT * INTO case_row FROM private.venta_solicitudes_devolucion cr WHERE cr.organization_id=p_org AND cr.id=case_id;
 IF NOT FOUND OR amount IS NULL OR amount<=0 OR amount>999999999999.99 OR amount<>round(amount,2) THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Valid refund case and exact positive amount required'; END IF;
 sale:=case_row.venta_id;
 ELSE
 reservation_id:=(p_payload->>'reservation_id')::uuid;
 SELECT * INTO reservation FROM private.refund_reservations rr WHERE rr.organization_id=p_org AND rr.id=reservation_id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Refund reservation not found'; END IF;
 sale:=reservation.venta_id; amount:=reservation.amount;
 END IF;
 -- Money source first, then account and sale: same lock order as cash collection.
 IF p_action IN ('settle','reverse') THEN
 IF p_action='reverse' THEN
 SELECT * INTO original FROM private.refund_fund_movements m WHERE m.organization_id=p_org AND m.reservation_id=reservation_id AND m.kind='payout';
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='No executed payout to reverse'; END IF;
 bank_id:=original.bank_id;session_id:=original.cash_session_id;
 IF at_time<original.effective_at THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Return precedes payout'; END IF;
 ELSE bank_id:=(p_payload->>'bank_id')::uuid;session_id:=(p_payload->>'cash_session_id')::uuid; END IF;
 IF (bank_id IS NULL)=(session_id IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Exactly one money source required'; END IF;
 IF bank_id IS NOT NULL THEN
 PERFORM pg_advisory_xact_lock(hashtextextended(p_org::text||':refund-bank:'||bank_id::text,0));
 SELECT * INTO bank FROM private.refund_bank_accounts b WHERE b.organization_id=p_org AND b.id=bank_id FOR UPDATE;
 IF NOT FOUND OR at_time<bank.reconciled_at THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Bank funds not reconciled for movement date'; END IF;
 IF bank.balance IS DISTINCT FROM (SELECT coalesce(sum(fm.delta),0) FROM private.refund_fund_movements fm WHERE fm.organization_id=p_org AND fm.bank_id=bank_id) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Bank projection not reconciled with evidence ledger'; END IF;
 available:=bank.balance;
 ELSE
 SELECT * INTO session_row FROM public.sesiones_caja s WHERE s.organization_id=p_org AND s.id=session_id FOR UPDATE;
 IF NOT FOUND OR session_row.estado<>'ABIERTA' OR session_row.fecha_cierre IS NOT NULL OR session_row.usuario_id IS DISTINCT FROM actor OR at_time<session_row.fecha_apertura
 OR NOT EXISTS(SELECT 1 FROM public.cash_registers r JOIN public.branches b ON b.organization_id=r.organization_id AND b.id=r.branch_id WHERE r.organization_id=p_org AND r.id=session_row.cash_register_id AND r.status='active' AND b.status='active') THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Own active cash session required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.empleados em WHERE em.organization_id=p_org AND em.branch_id=session_row.branch_id AND em.employment_status='active' AND em.activo AND (em.app_user_id=actor OR em.auth_id=actor)) THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Active cash custodian employee required'; END IF;
 available:=private.cash_session_available_balance(session_id);
 END IF;
 END IF;
 SELECT * INTO account FROM public.venta_cuentas_financieras a WHERE a.organization_id=p_org AND a.venta_id=sale FOR UPDATE;
 PERFORM 1 FROM public.ventas v WHERE v.organization_id=p_org AND v.id=sale FOR UPDATE;
 IF account.moneda IS DISTINCT FROM 'PEN' OR account.estado_conciliacion IS DISTINCT FROM 'conciliada' THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Reconciled PEN sale required'; END IF;
 SELECT * INTO audit FROM private.financial_2c_audit_sale(p_org,sale);
 IF NOT audit.apta_para_motor THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Refund pre-audit failed'; END IF;
 IF p_action<>'reserve' THEN
 SELECT * INTO reservation FROM private.refund_reservations rr WHERE rr.organization_id=p_org AND rr.id=reservation_id FOR UPDATE;
 SELECT * INTO case_row FROM private.venta_solicitudes_devolucion cr WHERE cr.organization_id=p_org AND cr.id=reservation.case_id;
 END IF;
 IF p_action IN ('reserve','settle') AND NOT EXISTS(SELECT 1 FROM public.notas_credito nc WHERE nc.organization_id=p_org AND nc.venta_id=sale AND nc.id=case_row.nota_credito_id AND nc.estado='aceptado' AND nc.afecta_dinero AND nc.estado_baja_tributaria='ninguna' AND nc.moneda='PEN') THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Refund NC no longer eligible'; END IF;
 IF p_action='reserve' THEN
 SELECT coalesce(sum(rr.amount),0) INTO held FROM private.refund_reservations rr WHERE rr.organization_id=p_org AND rr.venta_id=sale AND rr.state='held';
 SELECT -coalesce(sum(m.delta),0) INTO already_paid FROM private.refund_fund_movements m JOIN private.refund_reservations rr ON rr.organization_id=m.organization_id AND rr.id=m.reservation_id WHERE rr.organization_id=p_org AND rr.case_id=case_id;
 IF amount>account.excedente-held OR amount+already_paid>case_row.monto_solicitado OR EXISTS(SELECT 1 FROM private.refund_reservations rr WHERE rr.organization_id=p_org AND rr.case_id=case_id AND rr.state='held') THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Refund surplus or case limit unavailable'; END IF;
 INSERT INTO private.refund_reservations(organization_id,venta_id,case_id,amount,state,actor_id) VALUES(p_org,sale,case_id,amount,'held',actor) RETURNING id INTO reservation_id;
 result:=jsonb_build_object('success',true,'reservation_id',reservation_id,'state','held','amount',amount,'money_delivered',false,'funds_reserved',false);
 ELSIF p_action='release' THEN
 IF reservation.state<>'held' THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Only held reservation can be released'; END IF;
 UPDATE private.refund_reservations SET state='released' WHERE id=reservation_id;
 result:=jsonb_build_object('success',true,'reservation_id',reservation_id,'state','released','money_delivered',false);
 ELSE
 IF (p_action='settle' AND (reservation.state<>'held' OR amount>account.excedente OR amount>available)) OR
 (p_action='reverse' AND (reservation.state<>'paid' OR EXISTS(SELECT 1 FROM private.refund_fund_movements m WHERE m.organization_id=p_org AND m.reverses_id=original.id))) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Payout state, funds or surplus unavailable'; END IF;
 IF at_time<reservation.created_at THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Movement precedes reservation'; END IF;
 INSERT INTO public.venta_operaciones_financieras(organization_id,venta_id,tipo,request_id,actor_id,payload_hash,resultado)
 VALUES(p_org,sale,CASE WHEN p_action='settle' THEN 'devolucion' ELSE 'reversion_ajuste' END,p_request,actor,fp,'aplicado') RETURNING id INTO op;
 SELECT coalesce(max(secuencia),0)+1 INTO seq FROM public.venta_eventos_financieros e WHERE e.organization_id=p_org AND e.venta_id=sale;
 INSERT INTO public.venta_eventos_financieros(organization_id,venta_id,operacion_id,secuencia,tipo,delta_cobros,efectivo_at,reversa_evento_id)
 VALUES(p_org,sale,op,seq,CASE WHEN p_action='settle' THEN 'devolucion' ELSE 'reversion_ajuste' END,CASE WHEN p_action='settle' THEN -amount ELSE amount END,at_time,CASE WHEN p_action='reverse' THEN original.event_id END) RETURNING id INTO ev;
 INSERT INTO private.refund_fund_movements(organization_id,venta_id,reservation_id,event_id,bank_id,cash_session_id,cash_register_id,kind,delta,actor_id,evidence_ref,evidence_sha256,effective_at,reverses_id)
 VALUES(p_org,sale,reservation_id,ev,bank_id,session_id,session_row.cash_register_id,CASE WHEN p_action='settle' THEN 'payout' ELSE 'return' END,CASE WHEN p_action='settle' THEN -amount ELSE amount END,actor,evidence,digest,at_time,CASE WHEN p_action='reverse' THEN original.id END) RETURNING id INTO movement;
 IF bank_id IS NOT NULL THEN UPDATE private.refund_bank_accounts b SET balance=balance+CASE WHEN p_action='settle' THEN -amount ELSE amount END WHERE b.organization_id=p_org AND b.id=bank_id; END IF;
 UPDATE private.refund_reservations SET state=CASE WHEN p_action='settle' THEN 'paid' ELSE 'released' END WHERE id=reservation_id;
 new_c:=account.cobros_netos+CASE WHEN p_action='settle' THEN -amount ELSE amount END;
 new_d:=greatest(account.exigible-new_c,0);new_f:=greatest(new_c-account.exigible,0);
 -- Returning money after a fiscal baja may settle debt reopened by that baja.
 IF p_action='reverse' AND EXISTS(SELECT 1 FROM public.venta_cronogramas cr WHERE cr.organization_id=p_org AND cr.venta_id=sale) THEN
 IF NOT EXISTS(SELECT 1 FROM public.venta_cronogramas cr WHERE cr.organization_id=p_org AND cr.venta_id=sale AND cr.estado='vigente' AND cr.version=1) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unsupported refund schedule'; END IF;
 remaining:=account.saldo_pendiente-new_d;
 FOR q IN SELECT * FROM private.financial_2c4_installments(p_org,sale,NULL) ORDER BY vencimiento,numero LOOP
 piece:=least(remaining,q.saldo_pendiente);
 IF piece>0 THEN INSERT INTO public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado) VALUES(p_org,sale,q.cuota_id,ev,'ajuste',piece);remaining:=remaining-piece; END IF;
 END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Return allocation mismatch'; END IF;
 END IF;
 INSERT INTO private.refund_write_intents VALUES(p_org,sale,pg_current_xact_id());
 UPDATE public.venta_cuentas_financieras SET cobros_netos=new_c,saldo_pendiente=new_d,excedente=new_f,revision=revision+1,actualizado_at=clock_timestamp() WHERE organization_id=p_org AND venta_id=sale;
 UPDATE public.ventas SET saldo=new_d,estado=CASE WHEN new_d=0 THEN 'pagado' ELSE 'pendiente' END WHERE organization_id=p_org AND id=sale;
 DELETE FROM private.refund_write_intents WHERE organization_id=p_org AND venta_id=sale AND tx_id=pg_current_xact_id();
 SELECT * INTO audit FROM private.financial_2c_audit_sale(p_org,sale);
 IF NOT audit.apta_para_motor OR (EXISTS(SELECT 1 FROM public.venta_cronogramas cr WHERE cr.organization_id=p_org AND cr.venta_id=sale) AND (SELECT sum(saldo_pendiente) FROM private.financial_2c4_installments(p_org,sale,NULL)) IS DISTINCT FROM new_d) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Refund post-audit failed'; END IF;
 result:=jsonb_build_object('success',true,'reservation_id',reservation_id,'event_id',ev,'movement_id',movement,'amount',amount,'state',CASE WHEN p_action='settle' THEN 'paid' ELSE 'released' END,'recorded_from_evidence',true,'external_transfer_sent',false);
 END IF;
 END IF;
 INSERT INTO private.refund_commands(organization_id,request_id,action,fingerprint,actor_id,result) VALUES(p_org,p_request,p_action,fp,actor,result);
 RETURN result||jsonb_build_object('idempotent',false);
END $fn$;
REVOKE ALL ON FUNCTION private.financial_refund_command(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION private.financial_refund_command(uuid,uuid,text,jsonb) IS 'Private authorized accounting of evidenced refunds, not external bank dispatch; all client/service EXECUTE revoked.';

CREATE FUNCTION private.financial_refund_status(p_org uuid,p_sale bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $fn$
DECLARE a record; held numeric; delivered numeric; returned numeric;
BEGIN
 IF auth.uid() IS NULL OR private.current_organization_id() IS DISTINCT FROM p_org OR NOT private.has_permission('tenant.admin') THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Active tenant administrator required'; END IF;
 SELECT * INTO a FROM private.financial_2c_audit_sale(p_org,p_sale);
 IF NOT a.apta_para_motor THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Refund read requires reconciled sale'; END IF;
 SELECT coalesce(sum(r.amount),0) INTO held FROM private.refund_reservations r WHERE r.organization_id=p_org AND r.venta_id=p_sale AND r.state='held';
 SELECT -coalesce(sum(m.delta) FILTER(WHERE m.kind='payout'),0),coalesce(sum(m.delta) FILTER(WHERE m.kind='return'),0)
 INTO delivered,returned FROM private.refund_fund_movements m WHERE m.organization_id=p_org AND m.venta_id=p_sale;
 RETURN jsonb_build_object('venta_id',p_sale,'surplus',a.excedente_calculado,'reserved',held,'available',greatest(a.excedente_calculado-held,0),'payouts',delivered,'returns',returned,'net_delivered',delivered-returned,'funds_reserved',false,'authorizes_payout',false);
END $fn$;
REVOKE ALL ON FUNCTION private.financial_refund_status(uuid,bigint) FROM PUBLIC,anon,authenticated,service_role;

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
    IF TG_TABLE_NAME='ventas' AND TG_OP='UPDATE' THEN
      IF EXISTS(SELECT 1 FROM private.refund_write_intents ri JOIN public.venta_cuentas_financieras cf USING(organization_id,venta_id)
       WHERE ri.organization_id=v_new_org AND ri.venta_id=v_new_sale AND ri.tx_id=pg_current_xact_id()
       AND NEW.saldo=cf.saldo_pendiente AND NEW.estado=CASE WHEN cf.saldo_pendiente=0 THEN 'pagado' ELSE 'pendiente' END)
       AND (to_jsonb(NEW)-'saldo'-'estado')=(to_jsonb(OLD)-'saldo'-'estado') THEN RETURN NEW; END IF;
    END IF;
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
     ),0)+COALESCE((SELECT sum(fm.delta) FROM private.refund_fund_movements fm WHERE fm.organization_id=p_organization_id AND fm.venta_id=p_venta_id),0)<>v_c
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
  IF EXISTS(SELECT 1 FROM private.refund_fund_movements fm
      LEFT JOIN public.venta_eventos_financieros fe ON fe.organization_id=fm.organization_id AND fe.venta_id=fm.venta_id AND fe.id=fm.event_id
      LEFT JOIN private.refund_fund_movements origin ON origin.organization_id=fm.organization_id AND origin.id=fm.reverses_id
      WHERE fm.organization_id=p_organization_id AND fm.venta_id=p_venta_id
      AND (fe.id IS NULL OR fe.delta_exigible<>0 OR fe.delta_cobros<>fm.delta
       OR (fm.kind='payout' AND fe.tipo<>'devolucion')
       OR (fm.kind='return' AND (fe.tipo<>'reversion_ajuste' OR origin.kind IS DISTINCT FROM 'payout' OR origin.reservation_id IS DISTINCT FROM fm.reservation_id OR fm.delta IS DISTINCT FROM -origin.delta OR fe.reversa_evento_id IS DISTINCT FROM origin.event_id))))
    OR EXISTS(SELECT 1 FROM public.venta_eventos_financieros fe WHERE fe.organization_id=p_organization_id AND fe.venta_id=p_venta_id
       AND (fe.tipo='devolucion' OR (fe.tipo='reversion_ajuste' AND fe.delta_cobros<>0))
       AND NOT EXISTS(SELECT 1 FROM private.refund_fund_movements fm WHERE fm.organization_id=fe.organization_id AND fm.venta_id=fe.venta_id AND fm.event_id=fe.id)) THEN
    v_blockers:=array_append(v_blockers,'devoluciones_no_conciliadas');
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
CREATE OR REPLACE FUNCTION private.cash_session_available_balance(p_session_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_opening numeric;
  v_income numeric:=0;
  v_expense numeric:=0;
  v_employee_expense numeric:=0;
BEGIN
  SELECT s.monto_apertura INTO v_opening
  FROM public.sesiones_caja s
  WHERE s.organization_id=v_org AND s.id=p_session_id
    AND s.usuario_id=auth.uid() AND s.estado='ABIERTA';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Open cash session not available in current organization';
  END IF;

  SELECT COALESCE(sum(p.monto),0) INTO v_income
  FROM public.pagos_venta p
  WHERE p.organization_id=v_org AND p.cash_session_id=p_session_id;
  SELECT COALESCE(sum(p.monto),0) INTO v_expense
  FROM public.pagos_gasto p
  WHERE p.organization_id=v_org AND p.cash_session_id=p_session_id
    AND COALESCE(p.afecta_caja_chica,false);
  SELECT COALESCE(sum(p.monto),0) INTO v_employee_expense
  FROM public.pagos_empleados p
  WHERE p.organization_id=v_org AND p.cash_session_id=p_session_id
    AND COALESCE(p.afecta_caja_chica,false);

  RETURN COALESCE(v_opening,0)+v_income-v_expense-v_employee_expense+COALESCE((SELECT sum(m.delta) FROM private.refund_fund_movements m WHERE m.organization_id=v_org AND m.cash_session_id=p_session_id),0);
END;
$function$

;
CREATE OR REPLACE FUNCTION public.get_estado_caja_chica()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_session public.sesiones_caja;
  v_ingresos numeric:=0;
  v_egresos_gastos numeric:=0;
  v_egresos_personal numeric:=0;
BEGIN
  SELECT s.* INTO v_session FROM public.sesiones_caja s
  WHERE s.organization_id=v_org AND s.usuario_id=auth.uid() AND s.estado='ABIERTA'
  ORDER BY s.fecha_apertura DESC LIMIT 1;
  IF v_session.id IS NULL THEN RETURN json_build_object('estado','CERRADA','sesion',NULL); END IF;

  SELECT COALESCE(sum(p.monto),0) INTO v_ingresos FROM public.pagos_venta p
  WHERE p.organization_id=v_org AND p.cash_session_id=v_session.id;
  SELECT COALESCE(sum(p.monto),0) INTO v_egresos_gastos FROM public.pagos_gasto p
  WHERE p.organization_id=v_org AND p.cash_session_id=v_session.id AND COALESCE(p.afecta_caja_chica,false);
  SELECT COALESCE(sum(p.monto),0) INTO v_egresos_personal FROM public.pagos_empleados p
  WHERE p.organization_id=v_org AND p.cash_session_id=v_session.id AND COALESCE(p.afecta_caja_chica,false);

  v_egresos_gastos:=v_egresos_gastos-COALESCE((SELECT sum(m.delta) FROM private.refund_fund_movements m WHERE m.organization_id=v_org AND m.cash_session_id=v_session.id),0);
  RETURN json_build_object(
    'estado','ABIERTA','sesion',row_to_json(v_session),'ingresos_efectivo',v_ingresos,
    'egresos_efectivo',v_egresos_gastos+v_egresos_personal,
    'saldo_esperado',v_session.monto_apertura+v_ingresos-v_egresos_gastos-v_egresos_personal
  );
END;
$function$

;
