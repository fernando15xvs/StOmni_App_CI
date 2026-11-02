-- Fase 2B2: apertura transaccional exclusivamente administrativa con bloqueo fail-closed.
-- No habilita cobros nuevos, ventas a crédito, ni rutas cliente.
-- El corte exige una ventana de mantenimiento. El bloqueo de tablas protege
-- las fuentes durante la instantánea y los triggers impiden escritores legacy
-- DESPUES del commit para las ventas incorporadas al libro de eventos.

ALTER TABLE public.venta_operaciones_financieras
  ADD COLUMN IF NOT EXISTS metadata_apertura jsonb;

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
    v_sale := CASE WHEN TG_TABLE_NAME = 'ventas' THEN OLD.id ELSE OLD.venta_id END;
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
    v_sale := CASE WHEN TG_TABLE_NAME = 'ventas' THEN NEW.id ELSE NEW.venta_id END;
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

REVOKE ALL ON FUNCTION private.financial_2b_guard_legacy_financial_write()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER zz_fin2b_legacy_sale_guard
  BEFORE UPDATE OR DELETE ON public.ventas
  FOR EACH ROW
  EXECUTE FUNCTION private.financial_2b_guard_legacy_financial_write();

CREATE TRIGGER zz_fin2b_legacy_payment_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.pagos_venta
  FOR EACH ROW
  EXECUTE FUNCTION private.financial_2b_guard_legacy_financial_write();

CREATE TRIGGER zz_fin2b_legacy_credit_note_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.notas_credito
  FOR EACH ROW
  EXECUTE FUNCTION private.financial_2b_guard_legacy_financial_write();

CREATE OR REPLACE FUNCTION private.financial_2b_open_legacy_sale(
  p_organization_id uuid,
  p_venta_id bigint,
  p_request_id uuid,
  p_moneda_confirmada text,
  p_confirmar_corte boolean DEFAULT false
)
RETURNS TABLE (
  venta_id bigint,
  estado text,
  cantidad_eventos bigint,
  corte_at timestamptz
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $body$
DECLARE
  v_prev record;
  v_account record;
  v_existing_op record;
  v_op_id uuid;
  v_payment record;
  v_seq bigint := 1;
  v_corte timestamptz := clock_timestamp();
  v_total_paid numeric(14,2);
  v_expected_hash text;
BEGIN
  IF p_organization_id IS NULL OR p_venta_id IS NULL OR p_request_id IS NULL
      OR p_moneda_confirmada IS NULL OR p_confirmar_corte IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE='22023',
      MESSAGE='Apertura 2B exige organización, venta, request, moneda verificada y confirmación expresa del corte';
  END IF;
  IF p_moneda_confirmada !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Moneda de apertura no válida';
  END IF;

  -- Conflicta con cualquier INSERT/UPDATE/DELETE sobre el origen, incluso
  -- escritores sin soporte de advisory lock. Esperar a baja actividad.
  -- El guard AFTER COMMIT impide que vuelvan a modificar una cuenta abierta.
  LOCK TABLE public.ventas IN SHARE ROW EXCLUSIVE MODE;
  LOCK TABLE public.pagos_venta IN SHARE ROW EXCLUSIVE MODE;
  LOCK TABLE public.notas_credito IN SHARE ROW EXCLUSIVE MODE;
  LOCK TABLE public.comprobantes_electronicos IN SHARE ROW EXCLUSIVE MODE;

  SELECT cf.organization_id,cf.venta_id,cf.moneda,cf.creado_at
    INTO v_account
    FROM public.venta_cuentas_financieras AS cf
   WHERE cf.organization_id=p_organization_id AND cf.venta_id=p_venta_id
     FOR UPDATE;

  IF FOUND THEN
    SELECT op.id,op.request_id,op.resultado,op.metadata_apertura
      INTO v_existing_op
      FROM public.venta_operaciones_financieras AS op
      WHERE op.organization_id=p_organization_id AND op.venta_id=p_venta_id
        AND op.tipo='apertura'
      ORDER BY op.creado_at,op.id LIMIT 1;
    IF v_existing_op.request_id = p_request_id
      AND v_existing_op.resultado='aplicado'
      AND v_account.moneda=p_moneda_confirmada THEN
      RETURN QUERY
      SELECT p_venta_id, 'ya_abierta'::text,
             (SELECT count(*) FROM public.venta_eventos_financieros ev
               WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id),
             v_account.creado_at;
      RETURN;
    END IF;
    RAISE EXCEPTION USING ERRCODE='23505',
      MESSAGE='Venta ya abierta; request o moneda en conflicto';
  END IF;

  -- Garantizar que cada solicitud identifica como máximo una venta.
  IF EXISTS (
    SELECT 1 FROM public.venta_operaciones_financieras op
    WHERE op.organization_id=p_organization_id
      AND op.tipo='apertura' AND op.request_id=p_request_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23505',
      MESSAGE='request_id de apertura ya utilizado en otra venta';
  END IF;

  -- El diagnóstico está limitado a 1000 registros por tenant.
  -- Si la venta queda fuera, se rechaza: nunca se infiere que sea segura.
  SELECT p.* INTO v_prev
    FROM private.financial_2b_preview_sales(p_organization_id,1000) p
   WHERE p.venta_id=p_venta_id;

  IF NOT FOUND OR v_prev.estado_preconciliacion <> 'lista' THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Venta no conciliable automáticamente o fuera de ventana de preanálisis';
  END IF;

  IF v_prev.moneda <> p_moneda_confirmada THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Moneda confirmada diferente a la verificada por el diagnóstico';
  END IF;

  -- No se crea una cuenta supuestamente conciliada: la cobertura histórica
  -- anterior al corte puede ser parcial (pagos eliminados en el pasado).
  v_total_paid := v_prev.cobros_registrados;

  v_expected_hash := pg_catalog.md5(
      p_organization_id::text || ':' || p_venta_id::text || ':'
      || p_moneda_confirmada || ':' || v_prev.total_venta::text || ':'
      || v_total_paid::text || ':' || v_prev.saldo_guardado::text
  );

  INSERT INTO public.venta_cuentas_financieras(
    organization_id,venta_id,moneda,estado_conciliacion,exigible,
    cobros_netos,saldo_pendiente,excedente,revision,creado_at,actualizado_at
  ) VALUES(
    p_organization_id,p_venta_id,p_moneda_confirmada,'pendiente',
    v_prev.total_venta,v_total_paid,v_prev.saldo_estimado,0,1,v_corte,v_corte
  );

  INSERT INTO public.venta_operaciones_financieras(
    organization_id,venta_id,tipo,request_id,payload_hash,resultado,creado_at,
    actualizado_at,metadata_apertura
  ) VALUES(
    p_organization_id,p_venta_id,'apertura',p_request_id,v_expected_hash,
    'aplicado',v_corte,v_corte,
    pg_catalog.jsonb_build_object(
      'corte_at',v_corte,
      'moneda_confirmada',p_moneda_confirmada,
      'cobertura','fuentes_actuales_no_historial_exhaustivo',
      'total_venta',v_prev.total_venta,
      'cobros_registrados',v_total_paid,
      'saldo_guardado',v_prev.saldo_guardado,
      'observacion','Cobertura previa a corte no verificada; motor 2C inactivo'
    )
  ) RETURNING id INTO v_op_id;

  INSERT INTO public.venta_eventos_financieros(
    organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,
    delta_cobros,efectivo_at,registrado_at
  )
  SELECT p_organization_id,p_venta_id,v_op_id,v_seq,'apertura',
         v_prev.total_venta,0,v.fecha,v_corte
  FROM public.ventas v
  WHERE v.organization_id=p_organization_id AND v.id=p_venta_id;

  FOR v_payment IN
    SELECT pv.id,pv.fecha,pv.monto
      FROM public.pagos_venta pv
     WHERE pv.organization_id=p_organization_id AND pv.venta_id=p_venta_id
     ORDER BY pv.fecha,pv.id
  LOOP
    v_seq := v_seq + 1;
    INSERT INTO public.venta_eventos_financieros(
      organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,
      delta_cobros,efectivo_at,registrado_at,pago_id
    ) VALUES(
      p_organization_id,p_venta_id,v_op_id,v_seq,'cobro',
      0,v_payment.monto,v_payment.fecha,v_corte,v_payment.id
    );
  END LOOP;

  -- El historial de eventos reconstruido debe coincidir exactamente con el
  -- snapshot financiero; una divergencia revierte TODA la transacción.
  IF NOT EXISTS (
    SELECT 1 FROM public.venta_eventos_financieros ev
    WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id
    GROUP BY ev.organization_id,ev.venta_id
    HAVING SUM(ev.delta_exigible)=v_prev.total_venta
       AND SUM(ev.delta_cobros)=v_total_paid
       AND COUNT(*)=v_seq
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Apertura incompleta: los eventos no cuadran con el corte';
  END IF;

  RETURN QUERY SELECT p_venta_id,'abierta_pendiente_conciliacion'::text,
                      v_seq,v_corte;
END;
$body$;

REVOKE ALL ON FUNCTION private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)
  IS 'Apertura 2B exclusivamente administrativa, transaccional y fail-closed. Requiere ventana de mantenimiento; no activa el motor 2C.';
COMMENT ON FUNCTION private.financial_2b_guard_legacy_financial_write()
  IS 'Impide mutaciones legacy de ventas abiertas en ledger antes de activar rutas 2C.';
