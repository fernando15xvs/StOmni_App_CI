-- 2D-A: add a strictly validated, ticket-only credit sale entrypoint.
-- No change to v4 or electronic credit issuance. Existing offline tickets remain v4.
CREATE FUNCTION private.financial_2d_validate_terms(
 p_sale_at timestamptz,p_total numeric,p_initial numeric,p_payments jsonb,p_terms jsonb
) RETURNS numeric LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $fn$
DECLARE
 item jsonb; n integer:=0; due date; previous_due date;
 amount numeric; due_total numeric:=0; payments_total numeric:=0; payment jsonb;
BEGIN
 IF p_sale_at IS NULL OR NOT isfinite(p_sale_at)
    OR p_total IS NULL OR p_total<=0 OR p_total>999999999999.99 OR p_total<>round(p_total,2)
    OR p_initial IS NULL OR p_initial<0 OR p_initial>=p_total OR p_initial<>round(p_initial,2)
    OR p_payments IS NULL OR jsonb_typeof(p_payments)<>'array'
    OR p_terms IS NULL OR jsonb_typeof(p_terms)<>'array'
    OR jsonb_array_length(p_terms) NOT BETWEEN 1 AND 120 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Credit requires exact positive PEN balance, date and 1..120 installments';
 END IF;
 FOR payment IN SELECT value FROM jsonb_array_elements(p_payments) LOOP
  IF jsonb_typeof(payment)<>'object' OR jsonb_typeof(payment->'monto')<>'number'
     OR lower(btrim(payment->>'metodo'))<>'transferencia' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Credit v5 accepts only evidenced transfer down-payments; cash integration not enabled';
  END IF;
  amount:=(payment->>'monto')::numeric;
  IF amount<=0 OR amount>999999999999.99 OR amount<>round(amount,2) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Down-payment must contain exact positive cents';
  END IF;
  payments_total:=payments_total+amount;
 END LOOP;
 IF payments_total<>p_initial THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Credit down-payment must match payment details exactly';
 END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_terms) LOOP
  n:=n+1;
  IF jsonb_typeof(item)<>'object'
     OR jsonb_typeof(item->'number')<>'number'
     OR jsonb_typeof(item->'amount')<>'number'
     OR jsonb_typeof(item->'due_date')<>'string'
     OR (item->>'number')::numeric<>n
     OR item->>'due_date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Installments require sequential numbers, numeric amount and ISO date';
  END IF;
  BEGIN due:=(item->>'due_date')::date;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid installment due date';
  END;
  amount:=(item->>'amount')::numeric;
  IF to_char(due,'YYYY-MM-DD')<>item->>'due_date'
     OR due<=(p_sale_at AT TIME ZONE 'America/Lima')::date
     OR (previous_due IS NOT NULL AND due<previous_due)
     OR amount<=0 OR amount>999999999999.99 OR amount<>round(amount,2) THEN
   RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Installments must have ordered future dates and exact positive cents';
  END IF;
  due_total:=due_total+amount; previous_due:=due;
 END LOOP;
 IF due_total<>p_total-p_initial THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Installment sum must equal outstanding sale balance to the cent';
 END IF;
 RETURN due_total;
END $fn$;
REVOKE ALL ON FUNCTION private.financial_2d_validate_terms(timestamptz,numeric,numeric,jsonb,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.process_sale_credit_v5(
 p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
 p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
 p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
 p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
 p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint,
 p_credit_terms jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET "TimeZone"='UTC' AS $fn$
DECLARE
 v_org uuid; v_actor uuid:=auth.uid(); v_sale bigint; v_sale_row public.ventas%ROWTYPE;
 v_due numeric; v_paid numeric; v_count integer; v_fingerprint text; v_open public.venta_operaciones_financieras%ROWTYPE;
 v_result jsonb; v_op uuid; v_event uuid; v_schedule uuid; v_seq bigint:=1;
 v_payment record; v_term jsonb; v_configured boolean:=false; v_audit record;
BEGIN
 IF v_actor IS NULL OR NOT public.app_tiene_permiso('sales.create') THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authorized seller required';
 END IF;
 v_org:=private.require_current_organization_id();
 IF v_org IS NULL OR private.current_organization_id() IS DISTINCT FROM v_org
    OR p_request_id IS NULL OR p_es_credito IS DISTINCT FROM true
    OR lower(btrim(coalesce(p_tipo_comprobante,''))) NOT IN ('ticket_interno','ticket') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Credit v5 requires tenant, request and internal ticket; electronic credit is not enabled';
 END IF;
 -- Enforce exact fractions before the legacy engine can round the financial inputs.
 v_due:=private.financial_2d_validate_terms(p_fecha,p_total,p_monto_abono,p_pagos,p_credit_terms);
 IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' OR jsonb_array_length(p_detalles)=0 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Sale lines required';
 END IF;
 v_fingerprint:=encode(extensions.digest(jsonb_build_object(
  'org',v_org,'actor',v_actor,'request',p_request_id,'customer',p_cliente_id,
  'total',p_total,'date',p_fecha,'credit',p_es_credito,'down',p_monto_abono,
  'details',p_detalles,'payments',p_pagos,'terms',p_credit_terms,
  'quotation',p_cotizacion_id,'seller',p_vendedor_id,'document','ticket_interno',
  'discount_pct',p_descuento_global_porcentaje,'discount_amount',p_descuento_global_monto,
  'discount_reason',p_motivo_descuento,'gross_subtotal',p_subtotal_bruto,
  'discount_authorizer',p_descuento_autorizado_por
 )::text,'sha256'),'hex');

 -- Acquire the same request lock as process_sale_v3 to prevent two sale creations.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT id INTO v_sale FROM public.ventas WHERE organization_id=v_org AND request_id=p_request_id;
 IF FOUND THEN
  SELECT * INTO v_open FROM public.venta_operaciones_financieras
   WHERE organization_id=v_org AND venta_id=v_sale AND tipo='apertura'
   AND request_id=p_request_id AND resultado='aplicado';
  IF NOT FOUND OR v_open.payload_hash<>v_fingerprint OR v_open.resultado_payload IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Sale request is already used or credit terms differ';
  END IF;
  RETURN v_open.resultado_payload||jsonb_build_object('idempotent',true);
 END IF;

 SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_detalles) d
   WHERE d ? 'unit_profile_revision') INTO v_configured;
 IF v_configured THEN
  v_result:=public.process_sale_with_units_v4(
   p_request_id,p_cliente_id,p_total,p_fecha,true,p_monto_abono,p_detalles,p_pagos,
   p_cotizacion_id,p_vendedor_id,'ticket_interno',
   p_descuento_global_porcentaje,p_descuento_global_monto,
   p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
 ELSE
  v_result:=public.process_sale_v4(
   p_request_id,p_cliente_id,p_total,p_fecha,true,p_monto_abono,p_detalles,p_pagos,
   p_cotizacion_id,p_vendedor_id,'ticket_interno',
   p_descuento_global_porcentaje,p_descuento_global_monto,
   p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
 END IF;
 IF v_result->>'success'<>'true' OR v_result->>'idempotent'<>'false'
    OR v_result->>'venta_id' IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unexpected sale writer result; sale rolled back';
 END IF;
 v_sale:=(v_result->>'venta_id')::bigint;
 SELECT * INTO v_sale_row FROM public.ventas
  WHERE organization_id=v_org AND id=v_sale AND request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR v_sale_row.total IS DISTINCT FROM p_total
    OR v_sale_row.saldo IS DISTINCT FROM v_due THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Sale engine amount diverged from exact credit contract';
 END IF;
 -- Legacy v3 stores the outstanding balance but does not set fue_credito.
 -- Preserve existing UI, aging and reports semantics for the new v5 credit sale.
 UPDATE public.ventas SET fue_credito=true
 WHERE organization_id=v_org AND id=v_sale;
 SELECT coalesce(sum(monto),0),count(*) INTO v_paid,v_count FROM public.pagos_venta
  WHERE organization_id=v_org AND venta_id=v_sale;
 IF v_paid<>p_monto_abono OR v_count<>jsonb_array_length(p_pagos)
    OR EXISTS(SELECT 1 FROM public.venta_cuentas_financieras
      WHERE organization_id=v_org AND venta_id=v_sale) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Sale payment amounts or financial identity inconsistent';
 END IF;

 INSERT INTO public.venta_cuentas_financieras
  (organization_id,venta_id,moneda,estado_conciliacion,
   exigible,cobros_netos,saldo_pendiente,excedente,revision)
 VALUES(v_org,v_sale,'PEN','conciliada',p_total,v_paid,v_due,0,1);
 INSERT INTO public.venta_operaciones_financieras
  (organization_id,venta_id,tipo,request_id,actor_id,payload_hash,resultado,metadata_apertura)
 VALUES(v_org,v_sale,'apertura',p_request_id,v_actor,v_fingerprint,'aplicado',
  jsonb_build_object('cobertura','historico_auditado','origen','venta_credito_v5'))
 RETURNING id INTO v_op;
 INSERT INTO public.venta_eventos_financieros
  (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at)
 VALUES(v_org,v_sale,v_op,v_seq,'apertura',p_total,0,p_fecha) RETURNING id INTO v_event;

 FOR v_payment IN
  SELECT id,monto,fecha FROM public.pagos_venta
  WHERE organization_id=v_org AND venta_id=v_sale ORDER BY id
 LOOP
  v_seq:=v_seq+1;
  INSERT INTO public.venta_eventos_financieros
   (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at,pago_id)
  VALUES(v_org,v_sale,v_op,v_seq,'cobro',0,v_payment.monto,
    coalesce(v_payment.fecha,p_fecha),v_payment.id);
 END LOOP;
 INSERT INTO public.venta_cronogramas
  (organization_id,venta_id,version,estado,origen_evento_id,creado_por)
 VALUES(v_org,v_sale,1,'vigente',v_event,v_actor) RETURNING id INTO v_schedule;
 FOR v_term IN SELECT value FROM jsonb_array_elements(p_credit_terms) LOOP
  INSERT INTO public.venta_cuotas
   (organization_id,venta_id,cronograma_id,numero,vencimiento,
    es_legado,importe_original,importe_vigente)
  VALUES(v_org,v_sale,v_schedule,(v_term->>'number')::integer,
    (v_term->>'due_date')::date,false,(v_term->>'amount')::numeric,(v_term->>'amount')::numeric);
 END LOOP;
 SELECT * INTO v_audit FROM private.financial_2c_audit_sale(v_org,v_sale);
 IF v_audit.apta_para_motor IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit sale financial audit failed; all writes rolled back',
    DETAIL=array_to_string(v_audit.bloqueos,',');
 END IF;
 v_result:=v_result||jsonb_build_object('credit_schedule_id',v_schedule,'credit_schedule_version',1,
   'currency','PEN','balance',v_due,'initial_payment',v_paid);
 UPDATE public.venta_operaciones_financieras
  SET resultado_payload=v_result WHERE id=v_op AND organization_id=v_org AND venta_id=v_sale;
 RETURN v_result;
END $fn$;
-- SECURITY DEFINER is required because ledger DML is not exposed to clients.
REVOKE ALL ON FUNCTION public.process_sale_credit_v5(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.process_sale_credit_v5(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)
 TO authenticated;
