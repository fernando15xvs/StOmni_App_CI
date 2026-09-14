-- Fase 4.4 SaaS: ficha laboral por sucursal y pagos de personal tenant/cash-aware.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Ficha laboral: F1.3 ya creó organization_id + app_user_id opcional.
--    F4.4 añade sucursal principal y estado laboral explícito.
-- -----------------------------------------------------------------------------
ALTER TABLE public.empleados
  ADD COLUMN branch_id uuid,
  ADD COLUMN employment_status text;

UPDATE public.empleados e
SET branch_id=b.id
FROM public.branches b
WHERE e.branch_id IS NULL
  AND b.organization_id=e.organization_id
  AND b.is_main
  AND b.status='active';

UPDATE public.empleados
SET employment_status=CASE WHEN COALESCE(activo,false) THEN 'active' ELSE 'inactive' END
WHERE employment_status IS NULL;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.empleados WHERE organization_id IS NULL OR branch_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped employee remains before F4.4 contract';
  END IF;
END;
$guard$;

ALTER TABLE public.empleados
  ALTER COLUMN branch_id SET NOT NULL,
  ALTER COLUMN employment_status SET NOT NULL,
  ALTER COLUMN employment_status SET DEFAULT 'active',
  ADD CONSTRAINT empleados_organization_branch_fkey
    FOREIGN KEY(organization_id,branch_id) REFERENCES public.branches(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT empleados_employment_status_valid
    CHECK(employment_status IN ('active','inactive','leave','terminated'));

CREATE INDEX empleados_organization_branch_status_idx
  ON public.empleados(organization_id,branch_id,employment_status);

CREATE OR REPLACE FUNCTION private.enforce_employee_branch_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=COALESCE(private.current_organization_id(),NEW.organization_id);
  v_main_branch uuid;
BEGIN
  IF TG_OP='UPDATE' AND NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee organization is immutable';
  END IF;
  IF v_org IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Organization context required for employee';
  END IF;

  IF NEW.branch_id IS NULL THEN
    SELECT b.id INTO v_main_branch
    FROM public.branches b
    WHERE b.organization_id=v_org AND b.is_main AND b.status='active';
    NEW.branch_id:=v_main_branch;
  END IF;
  IF NEW.branch_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.branches b
    WHERE b.organization_id=v_org AND b.id=NEW.branch_id AND b.status='active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Active employee branch not available in current organization';
  END IF;

  IF TG_OP='UPDATE' AND NEW.activo IS DISTINCT FROM OLD.activo
     AND NEW.employment_status IS NOT DISTINCT FROM OLD.employment_status THEN
    NEW.employment_status:=CASE WHEN COALESCE(NEW.activo,false) THEN 'active' ELSE 'inactive' END;
  ELSE
    NEW.activo:=NEW.employment_status='active';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_employee_branch_status() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_empleados_branch_status
BEFORE INSERT OR UPDATE ON public.empleados
FOR EACH ROW EXECUTE FUNCTION private.enforce_employee_branch_status();

-- -----------------------------------------------------------------------------
-- 2. Pagos de empleados: ownership tenant y contexto de Caja.
-- -----------------------------------------------------------------------------
ALTER TABLE public.pagos_empleados
  ADD COLUMN organization_id uuid,
  ADD COLUMN cash_register_id uuid,
  ADD COLUMN cash_session_id uuid;

UPDATE public.pagos_empleados p
SET organization_id=e.organization_id
FROM public.empleados e
WHERE p.organization_id IS NULL AND p.empleado_id=e.id;

DO $payment_guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.pagos_empleados WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped employee payment remains before F4.4 contract';
  END IF;
END;
$payment_guard$;

ALTER TABLE public.pagos_empleados
  ALTER COLUMN organization_id SET NOT NULL,
  ADD CONSTRAINT pagos_empleados_organization_fkey
    FOREIGN KEY(organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_empleados_organization_id_id_key UNIQUE(organization_id,id);

ALTER TABLE public.pagos_empleados
  DROP CONSTRAINT IF EXISTS pagos_empleados_empleado_id_fkey;
ALTER TABLE public.pagos_empleados
  ADD CONSTRAINT pagos_empleados_organization_employee_fkey
    FOREIGN KEY(organization_id,empleado_id) REFERENCES public.empleados(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_empleados_organization_cash_register_fkey
    FOREIGN KEY(organization_id,cash_register_id) REFERENCES public.cash_registers(organization_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_empleados_organization_cash_session_fkey
    FOREIGN KEY(organization_id,cash_register_id,cash_session_id)
    REFERENCES public.sesiones_caja(organization_id,cash_register_id,id) ON DELETE RESTRICT;

CREATE INDEX pagos_empleados_organization_fecha_idx ON public.pagos_empleados(organization_id,fecha DESC);
CREATE INDEX pagos_empleados_org_cash_session_idx ON public.pagos_empleados(organization_id,cash_session_id) WHERE cash_session_id IS NOT NULL;

CREATE OR REPLACE FUNCTION private.enforce_employee_payment_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=COALESCE(private.current_organization_id(),NEW.organization_id);
  v_employee_org uuid;
  v_affects boolean;
  v_session public.sesiones_caja;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
       OR NEW.cash_register_id IS DISTINCT FROM OLD.cash_register_id
       OR NEW.cash_session_id IS DISTINCT FROM OLD.cash_session_id THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee payment tenant/cash context is immutable';
    END IF;
    RETURN NEW;
  END IF;

  SELECT e.organization_id INTO v_employee_org
  FROM public.empleados e
  WHERE e.id=NEW.empleado_id;
  IF v_employee_org IS NULL OR v_org IS NULL OR v_employee_org IS DISTINCT FROM v_org THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Employee payment belongs to another organization';
  END IF;
  NEW.organization_id:=v_org;

  v_affects:=COALESCE(NEW.afecta_caja_chica,false)
    AND upper(btrim(COALESCE(NEW.metodo,''))) LIKE '%EFECTIVO%';
  IF NOT v_affects THEN
    NEW.cash_register_id:=NULL;
    NEW.cash_session_id:=NULL;
    RETURN NEW;
  END IF;

  IF NEW.cash_session_id IS NULL THEN
    NEW.cash_session_id:=private.require_open_cash_session_id();
  END IF;
  SELECT s.* INTO v_session
  FROM public.sesiones_caja s
  WHERE s.organization_id=v_org AND s.id=NEW.cash_session_id
    AND s.usuario_id=auth.uid() AND s.estado='ABIERTA';
  IF v_session.id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Open cash session not available for employee payment';
  END IF;
  NEW.cash_register_id:=v_session.cash_register_id;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_employee_payment_context() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pagos_empleados_enforce_context
BEFORE INSERT OR UPDATE ON public.pagos_empleados
FOR EACH ROW EXECUTE FUNCTION private.enforce_employee_payment_context();

ALTER TABLE public.pagos_empleados ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pagos_empleados_select_admin ON public.pagos_empleados;
DROP POLICY IF EXISTS pagos_empleados_insert_admin ON public.pagos_empleados;
CREATE POLICY pagos_empleados_tenant_admin_select ON public.pagos_empleados
FOR SELECT TO authenticated
USING(private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
REVOKE ALL ON TABLE public.pagos_empleados FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.pagos_empleados TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Saldo de Caja incorpora pagos de personal de la misma sesión.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.cash_session_available_balance(p_session_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
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

  RETURN COALESCE(v_opening,0)+v_income-v_expense-v_employee_expense;
END;
$$;
REVOKE ALL ON FUNCTION private.cash_session_available_balance(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.cash_session_available_balance(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. RPC de pago de personal: reemplaza la versión global y reabre el runtime.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_pago_empleado_mixto(
  p_empleado_id bigint,p_concepto text,p_fecha timestamptz,p_pagos_json jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_pago jsonb;
  v_monto numeric;
  v_metodo text;
  v_afecta boolean;
  v_cash_total numeric:=0;
  v_fecha timestamptz:=COALESCE(p_fecha,now());
  v_session_id uuid;
  v_available numeric;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin permission required for employee payments';
  END IF;
  IF p_empleado_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.empleados e
    WHERE e.organization_id=v_org AND e.id=p_empleado_id
      AND e.employment_status<>'terminated'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee not available in current organization';
  END IF;
  IF NULLIF(btrim(COALESCE(p_concepto,'')),'') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Employee payment concept is required';
  END IF;
  IF p_pagos_json IS NULL OR jsonb_typeof(p_pagos_json)<>'array' OR jsonb_array_length(p_pagos_json)=0 THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='At least one employee payment is required';
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    IF jsonb_typeof(v_pago)<>'object' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Each employee payment must be an object';
    END IF;
    v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
    v_metodo:=btrim(COALESCE(v_pago->>'metodo',''));
    IF v_monto<=0 OR v_metodo='' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Employee payment requires positive amount and method';
    END IF;
    v_afecta:=COALESCE((v_pago->>'afecta_caja_chica')::boolean,false)
      AND upper(v_metodo) LIKE '%EFECTIVO%';
    IF v_afecta THEN v_cash_total:=v_cash_total+v_monto; END IF;
  END LOOP;

  IF v_cash_total>0 THEN
    v_session_id:=private.require_open_cash_session_id();
    IF v_fecha < (SELECT s.fecha_apertura FROM public.sesiones_caja s WHERE s.organization_id=v_org AND s.id=v_session_id) THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee cash payment date cannot precede cash session opening';
    END IF;
    v_available:=private.cash_session_available_balance(v_session_id);
    IF v_cash_total>v_available+0.000001 THEN
      RAISE EXCEPTION 'Saldo insuficiente en Caja. Disponible: S/ %, solicitado: S/ %.',
        round(v_available,2),round(v_cash_total,2) USING ERRCODE='23514';
    END IF;
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
    v_metodo:=btrim(COALESCE(v_pago->>'metodo',''));
    v_afecta:=COALESCE((v_pago->>'afecta_caja_chica')::boolean,false)
      AND upper(v_metodo) LIKE '%EFECTIVO%';
    INSERT INTO public.pagos_empleados(
      organization_id,empleado_id,monto,concepto,metodo,fecha,afecta_caja_chica,cash_session_id
    ) VALUES(
      v_org,p_empleado_id,v_monto,btrim(p_concepto),v_metodo,v_fecha,v_afecta,
      CASE WHEN v_afecta THEN v_session_id ELSE NULL END
    );
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.registrar_pago_empleado_mixto(bigint,text,timestamptz,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_pago_empleado_mixto(bigint,text,timestamptz,jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Reincorporar pagos de personal a vistas financieras, ahora tenant-safe.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.movimientos
WITH (security_invoker=true)
AS
SELECT pv.id,'Cobro de Venta #'::text||pv.venta_id AS descripcion,pv.monto,'ingreso'::text AS tipo,
  pv.fecha,pv.venta_id,NULL::bigint AS gasto_id,NULL::bigint AS pago_empleado_id,pv.metodo,true AS afecta_caja_chica,
  pv.organization_id,pv.cash_register_id,pv.cash_session_id
FROM public.pagos_venta pv
UNION ALL
SELECT pg.id,'Pago de Gasto: '::text||COALESCE(g.categoria,'Varios'),pg.monto,'egreso'::text,
  pg.fecha,NULL::bigint,pg.gasto_id,NULL::bigint,pg.metodo,COALESCE(pg.afecta_caja_chica,false),
  pg.organization_id,pg.cash_register_id,pg.cash_session_id
FROM public.pagos_gasto pg
LEFT JOIN public.gastos g ON g.organization_id=pg.organization_id AND g.id=pg.gasto_id
UNION ALL
SELECT pe.id,'Pago a Personal: '::text||COALESCE(e.nombre,'Empleado')||
  CASE WHEN NULLIF(btrim(COALESCE(pe.concepto,'')),'') IS NULL THEN '' ELSE ' - '||pe.concepto END,
  pe.monto,'egreso'::text,pe.fecha,NULL::bigint,NULL::bigint,pe.id,pe.metodo,COALESCE(pe.afecta_caja_chica,false),
  pe.organization_id,pe.cash_register_id,pe.cash_session_id
FROM public.pagos_empleados pe
LEFT JOIN public.empleados e ON e.organization_id=pe.organization_id AND e.id=pe.empleado_id;

CREATE OR REPLACE VIEW public.reportes_movimientos_financieros
WITH (security_invoker=true)
AS
SELECT pv.id,'pago_venta'::text AS origen,pv.id AS origen_id,'Cobro de Venta #'::text||pv.venta_id AS descripcion,
  pv.monto,'ingreso'::text AS tipo,COALESCE(NULLIF(btrim(pv.metodo),''),'Otro') AS metodo,pv.fecha,pv.venta_id,
  NULL::bigint AS gasto_id,NULL::bigint AS pago_empleado_id,pv.organization_id,pv.cash_register_id,pv.cash_session_id
FROM public.pagos_venta pv WHERE private.has_permission('tenant.admin')
UNION ALL
SELECT pg.id,'pago_gasto',pg.id,'Pago de Gasto: '::text||COALESCE(g.categoria,'Varios'),pg.monto,'egreso',
  COALESCE(NULLIF(btrim(pg.metodo),''),'Otro'),pg.fecha,NULL::bigint,pg.gasto_id,NULL::bigint,
  pg.organization_id,pg.cash_register_id,pg.cash_session_id
FROM public.pagos_gasto pg
LEFT JOIN public.gastos g ON g.organization_id=pg.organization_id AND g.id=pg.gasto_id
WHERE private.has_permission('tenant.admin')
UNION ALL
SELECT pe.id,'pago_empleado',pe.id,'Pago a Personal: '::text||COALESCE(e.nombre,'Empleado')||
  CASE WHEN NULLIF(btrim(COALESCE(pe.concepto,'')),'') IS NULL THEN '' ELSE ' - '||pe.concepto END,
  pe.monto,'egreso',COALESCE(NULLIF(btrim(pe.metodo),''),'Otro'),pe.fecha,NULL::bigint,NULL::bigint,pe.id,
  pe.organization_id,pe.cash_register_id,pe.cash_session_id
FROM public.pagos_empleados pe
LEFT JOIN public.empleados e ON e.organization_id=pe.organization_id AND e.id=pe.empleado_id
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

  RETURN json_build_object(
    'estado','ABIERTA','sesion',row_to_json(v_session),'ingresos_efectivo',v_ingresos,
    'egresos_efectivo',v_egresos_gastos+v_egresos_personal,
    'saldo_esperado',v_session.monto_apertura+v_ingresos-v_egresos_gastos-v_egresos_personal
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_estado_caja_chica() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_estado_caja_chica() TO authenticated;

COMMIT;
