-- Fase 4.3 SaaS (parte 2): atribución de movimientos a sesión de caja.
BEGIN;

ALTER TABLE public.cash_registers
  ADD CONSTRAINT cash_registers_organization_id_id_key UNIQUE(organization_id,id);

ALTER TABLE public.pagos_venta
  ADD COLUMN cash_register_id uuid,
  ADD COLUMN cash_session_id uuid;
ALTER TABLE public.pagos_gasto
  ADD COLUMN cash_register_id uuid,
  ADD COLUMN cash_session_id uuid;

COMMENT ON COLUMN public.pagos_venta.cash_session_id IS 'Sesión de caja que recibió el pago efectivo. NULL para pagos no-cash o históricos anteriores a F4.3.';
COMMENT ON COLUMN public.pagos_gasto.cash_session_id IS 'Sesión de caja afectada por el egreso efectivo. NULL para pagos no-cash/no-caja o históricos anteriores a F4.3.';

ALTER TABLE public.pagos_venta
  ADD CONSTRAINT pagos_venta_organization_cash_register_fkey
    FOREIGN KEY(organization_id,cash_register_id) REFERENCES public.cash_registers(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_venta_organization_cash_session_fkey
    FOREIGN KEY(organization_id,cash_register_id,cash_session_id)
    REFERENCES public.sesiones_caja(organization_id,cash_register_id,id) ON DELETE RESTRICT;
ALTER TABLE public.pagos_gasto
  ADD CONSTRAINT pagos_gasto_organization_cash_register_fkey
    FOREIGN KEY(organization_id,cash_register_id) REFERENCES public.cash_registers(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_gasto_organization_cash_session_fkey
    FOREIGN KEY(organization_id,cash_register_id,cash_session_id)
    REFERENCES public.sesiones_caja(organization_id,cash_register_id,id) ON DELETE RESTRICT;

CREATE INDEX pagos_venta_org_cash_session_idx ON public.pagos_venta(organization_id,cash_session_id) WHERE cash_session_id IS NOT NULL;
CREATE INDEX pagos_gasto_org_cash_session_idx ON public.pagos_gasto(organization_id,cash_session_id) WHERE cash_session_id IS NOT NULL;

CREATE OR REPLACE FUNCTION private.enforce_cash_payment_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=COALESCE(private.current_organization_id(),NEW.organization_id);
  v_affects boolean;
  v_session public.sesiones_caja;
  v_count integer;
  v_row jsonb:=to_jsonb(NEW);
BEGIN
  IF TG_OP='UPDATE' THEN
    IF NEW.cash_register_id IS DISTINCT FROM OLD.cash_register_id
       OR NEW.cash_session_id IS DISTINCT FROM OLD.cash_session_id THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cash payment session is immutable';
    END IF;
    RETURN NEW;
  END IF;

  IF v_org IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Organization context required for cash payment';
  END IF;

  v_affects := upper(btrim(COALESCE(NEW.metodo,''))) LIKE '%EFECTIVO%';
  IF TG_TABLE_NAME='pagos_gasto' THEN
    v_affects := v_affects AND COALESCE((v_row->>'afecta_caja_chica')::boolean,false);
  END IF;

  IF NOT v_affects THEN
    NEW.cash_register_id:=NULL;
    NEW.cash_session_id:=NULL;
    RETURN NEW;
  END IF;

  IF NEW.cash_session_id IS NOT NULL THEN
    SELECT s.* INTO v_session
    FROM public.sesiones_caja s
    WHERE s.organization_id=v_org
      AND s.id=NEW.cash_session_id
      AND s.estado='ABIERTA'
      AND (auth.uid() IS NULL OR s.usuario_id=auth.uid());
    IF v_session.id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Open cash session not available for current user';
    END IF;
  ELSE
    SELECT count(*) INTO v_count
    FROM public.sesiones_caja s
    WHERE s.organization_id=v_org AND s.estado='ABIERTA'
      AND (auth.uid() IS NULL OR s.usuario_id=auth.uid());
    IF v_count=0 THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Open cash session required for cash movement';
    ELSIF v_count>1 THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple open cash sessions require explicit cash_session_id';
    END IF;
    SELECT s.* INTO v_session
    FROM public.sesiones_caja s
    WHERE s.organization_id=v_org AND s.estado='ABIERTA'
      AND (auth.uid() IS NULL OR s.usuario_id=auth.uid())
    LIMIT 1;
  END IF;

  NEW.cash_register_id:=v_session.cash_register_id;
  NEW.cash_session_id:=v_session.id;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_cash_payment_context() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER zz_pagos_venta_enforce_cash_session
BEFORE INSERT OR UPDATE ON public.pagos_venta
FOR EACH ROW EXECUTE FUNCTION private.enforce_cash_payment_context();
CREATE TRIGGER zz_pagos_gasto_enforce_cash_session
BEFORE INSERT OR UPDATE ON public.pagos_gasto
FOR EACH ROW EXECUTE FUNCTION private.enforce_cash_payment_context();

-- Las vistas financieras dejan de ejecutar con privilegios del owner y exponen
-- organization/cash context. Pagos de empleados se reincorporan en F4.4 una vez
-- tenantificados; incluirlos ahora reabriría una fuga conocida.
CREATE OR REPLACE VIEW public.movimientos
WITH (security_invoker=true)
AS
SELECT
  pv.id,
  'Cobro de Venta #'::text || pv.venta_id AS descripcion,
  pv.monto,
  'ingreso'::text AS tipo,
  pv.fecha,
  pv.venta_id,
  NULL::bigint AS gasto_id,
  NULL::bigint AS pago_empleado_id,
  pv.metodo,
  true AS afecta_caja_chica,
  pv.organization_id,
  pv.cash_register_id,
  pv.cash_session_id
FROM public.pagos_venta pv
UNION ALL
SELECT
  pg.id,
  'Pago de Gasto: '::text || COALESCE(g.categoria,'Varios'::text),
  pg.monto,
  'egreso'::text,
  pg.fecha,
  NULL::bigint,
  pg.gasto_id,
  NULL::bigint,
  pg.metodo,
  COALESCE(pg.afecta_caja_chica,false),
  pg.organization_id,
  pg.cash_register_id,
  pg.cash_session_id
FROM public.pagos_gasto pg
LEFT JOIN public.gastos g ON g.organization_id=pg.organization_id AND g.id=pg.gasto_id;

CREATE OR REPLACE VIEW public.reportes_movimientos_financieros
WITH (security_invoker=true)
AS
SELECT
  pv.id,
  'pago_venta'::text AS origen,
  pv.id AS origen_id,
  'Cobro de Venta #'::text || pv.venta_id AS descripcion,
  pv.monto,
  'ingreso'::text AS tipo,
  COALESCE(NULLIF(btrim(pv.metodo),''),'Otro'::text) AS metodo,
  pv.fecha,
  pv.venta_id,
  NULL::bigint AS gasto_id,
  NULL::bigint AS pago_empleado_id,
  pv.organization_id,
  pv.cash_register_id,
  pv.cash_session_id
FROM public.pagos_venta pv
WHERE private.has_permission('tenant.admin')
UNION ALL
SELECT
  pg.id,
  'pago_gasto'::text,
  pg.id,
  'Pago de Gasto: '::text || COALESCE(g.categoria,'Varios'::text),
  pg.monto,
  'egreso'::text,
  COALESCE(NULLIF(btrim(pg.metodo),''),'Otro'::text),
  pg.fecha,
  NULL::bigint,
  pg.gasto_id,
  NULL::bigint,
  pg.organization_id,
  pg.cash_register_id,
  pg.cash_session_id
FROM public.pagos_gasto pg
LEFT JOIN public.gastos g ON g.organization_id=pg.organization_id AND g.id=pg.gasto_id
WHERE private.has_permission('tenant.admin');

REVOKE ALL ON public.movimientos,public.reportes_movimientos_financieros FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.movimientos TO authenticated;
GRANT SELECT ON public.reportes_movimientos_financieros TO authenticated;

CREATE OR REPLACE FUNCTION public.get_estado_caja_chica()
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_session public.sesiones_caja;
  v_ingresos numeric:=0;
  v_egresos numeric:=0;
BEGIN
  SELECT s.* INTO v_session
  FROM public.sesiones_caja s
  WHERE s.organization_id=v_org
    AND s.usuario_id=auth.uid()
    AND s.estado='ABIERTA'
  ORDER BY s.fecha_apertura DESC
  LIMIT 1;

  IF v_session.id IS NULL THEN
    RETURN json_build_object('estado','CERRADA','sesion',NULL);
  END IF;

  SELECT COALESCE(sum(p.monto),0) INTO v_ingresos
  FROM public.pagos_venta p
  WHERE p.organization_id=v_org AND p.cash_session_id=v_session.id;

  SELECT COALESCE(sum(p.monto),0) INTO v_egresos
  FROM public.pagos_gasto p
  WHERE p.organization_id=v_org AND p.cash_session_id=v_session.id
    AND COALESCE(p.afecta_caja_chica,false);

  RETURN json_build_object(
    'estado','ABIERTA',
    'sesion',row_to_json(v_session),
    'ingresos_efectivo',v_ingresos,
    'egresos_efectivo',v_egresos,
    'saldo_esperado',v_session.monto_apertura+v_ingresos-v_egresos
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_estado_caja_chica() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_estado_caja_chica() TO authenticated;

COMMIT;
