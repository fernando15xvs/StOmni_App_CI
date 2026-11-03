-- 2C5A full reversal of transfer payments, no cash refunds.
-- Original payment and installment applications remain immutable.
ALTER TABLE private.financial_2c2_write_intents
  DROP CONSTRAINT financial_2c2_write_intents_metodo_check;
ALTER TABLE private.financial_2c2_write_intents
  ADD CONSTRAINT financial_2c2_write_intents_metodo_check
  CHECK (metodo IN ('efectivo','transferencia','reverso_transferencia'));
ALTER TABLE private.financial_2c2_write_intents
  DROP CONSTRAINT financial_2c3b_intent_cash_context_check;
ALTER TABLE private.financial_2c2_write_intents
  ADD CONSTRAINT financial_2c3b_intent_cash_context_check CHECK (
    (metodo IN ('transferencia','reverso_transferencia')
      AND actor_id IS NULL AND cash_session_id IS NULL AND cash_register_id IS NULL)
    OR (metodo='efectivo' AND actor_id IS NOT NULL
      AND cash_session_id IS NOT NULL AND cash_register_id IS NOT NULL)
  );
CREATE UNIQUE INDEX venta_eventos_2c5_unique_full_reversal
 ON public.venta_eventos_financieros(organization_id,venta_id,reversa_evento_id)
 WHERE tipo='reverso';
CREATE UNIQUE INDEX venta_cuota_mov_2c5_unique_reversal
 ON public.venta_cuota_movimientos(organization_id,venta_id,reversa_movimiento_id)
 WHERE tipo='reverso';
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
$function$;

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
    WHERE nc.organization_id=p_organization_id AND nc.venta_id=p_venta_id;

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
$function$;

REVOKE ALL ON FUNCTION private.financial_2b_guard_legacy_financial_write() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION private.financial_2c_audit_sale(uuid,bigint) FROM PUBLIC,anon,authenticated,service_role;
