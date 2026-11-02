-- 2C1: validación canónica y preflight estricto (sin escrituras, sin API cliente).
-- El pago sigue deshabilitado hasta integrar caja, permisos, operaciones y eventos
-- en una sola transacción. Ninguna función de esta migración actualiza tablas.

CREATE FUNCTION private.financial_2c_audit_sale(
  p_organization_id uuid,
  p_venta_id bigint
)
RETURNS TABLE (
  organization_id uuid,
  venta_id bigint,
  moneda text,
  exigible_eventos numeric,
  cobros_eventos numeric,
  saldo_calculado numeric,
  excedente_calculado numeric,
  estado_conciliacion text,
  revision bigint,
  apta_para_motor boolean,
  bloqueos text[]
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
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
  IF v_payment_count<>v_payment_events
     OR v_payment_events<>v_distinct_payment_events
     OR v_payment_sum<>v_c
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
$fn$;

CREATE FUNCTION private.financial_2c_preflight_payment(
  p_organization_id uuid,
  p_venta_id bigint,
  p_request_id uuid,
  p_moneda text,
  p_monto numeric,
  p_metodo text,
  p_fecha timestamptz
)
RETURNS TABLE (
  permitido boolean,
  codigo text,
  saldo_actual numeric,
  saldo_despues numeric,
  revision bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
DECLARE
  v_a record;
  v_code text;
BEGIN
  -- No redondear ni aceptar sobrepagos de 0.01.
  IF p_organization_id IS NULL OR p_venta_id IS NULL OR p_request_id IS NULL
     OR p_moneda IS NULL OR p_metodo IS NULL OR p_fecha IS NULL
     OR p_monto IS NULL THEN
    v_code:='payload_incompleto';
  ELSIF p_monto<=0 OR p_monto<>ROUND(p_monto,2)
     OR p_monto>999999999999.99 THEN
    v_code:='monto_invalido_centavos';
  ELSIF p_moneda !~ '^[A-Z]{3}$' OR LENGTH(BTRIM(p_metodo))=0 THEN
    v_code:='moneda_o_metodo_invalido';
  ELSIF UPPER(p_metodo) LIKE '%EFECTIVO%' THEN
    v_code:='caja_no_integrada';
  END IF;

  IF p_organization_id IS NOT NULL AND p_venta_id IS NOT NULL THEN
    SELECT * INTO v_a FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id);
  END IF;

  IF v_code IS NULL THEN
    IF v_a.venta_id IS NULL OR v_a.estado_conciliacion='ausente' THEN
      v_code:='cuenta_no_abierta';
    ELSIF v_a.moneda IS DISTINCT FROM p_moneda THEN
      v_code:='moneda_distinta';
    ELSIF NOT v_a.apta_para_motor THEN
      v_code:='conciliacion_no_aprobada';
    ELSIF EXISTS (
      SELECT 1 FROM public.venta_operaciones_financieras op
      WHERE op.organization_id=p_organization_id
        AND op.tipo='cobro' AND op.request_id=p_request_id
    ) THEN
      v_code:='request_existente_requiere_resolucion';
    ELSIF p_monto>v_a.saldo_calculado THEN
      v_code:='monto_supera_saldo';
    ELSE
      v_code:='preflight_aprobado_sin_registro';
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_code='preflight_aprobado_sin_registro',v_code,
    v_a.saldo_calculado,
    CASE WHEN v_code='preflight_aprobado_sin_registro'
         THEN v_a.saldo_calculado-p_monto ELSE NULL::numeric END,
    v_a.revision;
END;
$fn$;

-- Uso administrativo en pruebas. No abrir ENDPOINTS hasta 2C2/2C3.
REVOKE ALL ON FUNCTION private.financial_2c_audit_sale(uuid,bigint)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION private.financial_2c_audit_sale(uuid,bigint)
  IS 'Bloque 2C1: auditoría canónica por eventos, saldos y pagos de origen. Solo lectura; nunca concilia automáticamente.';
COMMENT ON FUNCTION private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)
  IS 'Bloque 2C1: valida importe exacto y precondiciones pero NO registra cobros. No expuesto al cliente.';
