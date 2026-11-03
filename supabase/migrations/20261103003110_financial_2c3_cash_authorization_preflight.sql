-- 2C3A: autorizacion tenant-aware de cobros en efectivo, SOLO LECTURA.
-- Un actor explicitado por administracion nunca concede permisos al frontend:
-- EXECUTE permanece revocado hasta crear un RPC que derive actor de auth.uid().
-- No crea pagos, no mueve caja y no reemplaza el writer 2C2.

INSERT INTO public.permissions (code,category,name,is_active)
VALUES ('sales.collect','sales','Registrar cobros de ventas',true)
ON CONFLICT (code) DO NOTHING;

CREATE FUNCTION private.financial_2c3_cash_preflight(
 p_organization_id uuid,
 p_venta_id bigint,
 p_request_id uuid,
 p_actor_id uuid,
 p_cash_session_id uuid,
 p_monto numeric,
 p_fecha timestamptz
)
RETURNS TABLE (
 permitido boolean,
 codigo text,
 cash_register_id uuid,
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
 v_code text;
 v_account record;
 v_saldo numeric;
 v_revision bigint;
 v_moneda text;
 v_sale_date timestamptz;
 v_session_status text;
 v_session_owner uuid;
 v_opened_at timestamptz;
 v_closed_at timestamptz;
 v_cash_register uuid;
 v_cash_register_status text;
 v_branch_status text;
 v_branch uuid;
 v_employee_id bigint;
 v_admin boolean := false;
 v_override boolean;
 v_granted boolean := false;
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL
    OR p_request_id IS NULL OR p_actor_id IS NULL
    OR p_cash_session_id IS NULL OR p_monto IS NULL OR p_fecha IS NULL THEN
   v_code:='payload_incompleto';
 ELSIF p_monto<=0 OR p_monto<>ROUND(p_monto,2)
       OR p_monto>999999999999.99 THEN
   v_code:='monto_invalido_centavos';
 ELSIF p_fecha>now() THEN
   v_code:='fecha_futura';
 ELSIF auth.uid() IS NOT NULL AND auth.uid() IS DISTINCT FROM p_actor_id THEN
   v_code:='actor_no_coincide_jwt';
 END IF;

 IF v_code IS NULL THEN
   SELECT a.* INTO v_account
   FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id) a;
   v_saldo:=v_account.saldo_calculado;
   v_revision:=v_account.revision;
   v_moneda:=v_account.moneda;

   IF NOT FOUND OR v_account.estado_conciliacion='ausente' THEN
     v_code:='cuenta_no_abierta';
   ELSIF v_moneda<>'PEN' THEN
     v_code:='moneda_no_pen';
   ELSIF NOT v_account.apta_para_motor THEN
     v_code:='conciliacion_no_aprobada';
   ELSIF p_monto>v_saldo THEN
     v_code:='monto_supera_saldo';
   ELSIF EXISTS (
      SELECT 1 FROM public.venta_operaciones_financieras op
       WHERE op.organization_id=p_organization_id AND op.tipo='cobro'
         AND op.request_id=p_request_id
   ) THEN
     v_code:='request_existente';
   END IF;
 END IF;

 IF v_code IS NULL THEN
   SELECT v.fecha INTO v_sale_date
   FROM public.ventas v
   WHERE v.organization_id=p_organization_id AND v.id=p_venta_id;
   IF v_sale_date IS NULL OR p_fecha<v_sale_date THEN
     v_code:='fecha_anterior_venta';
   END IF;
 END IF;

 IF v_code IS NULL THEN
   SELECT s.estado,s.usuario_id,s.fecha_apertura,s.fecha_cierre,
          s.cash_register_id,s.branch_id,r.status,b.status
   INTO v_session_status,v_session_owner,v_opened_at,v_closed_at,
        v_cash_register,v_branch,v_cash_register_status,v_branch_status
   FROM public.sesiones_caja s
   JOIN public.cash_registers r
     ON r.organization_id=s.organization_id AND r.branch_id=s.branch_id
     AND r.id=s.cash_register_id
   JOIN public.branches b
     ON b.organization_id=s.organization_id AND b.id=s.branch_id
   WHERE s.organization_id=p_organization_id
     AND s.id=p_cash_session_id;

   IF NOT FOUND THEN
     v_code:='sesion_fuera_organizacion';
   ELSIF v_session_owner IS DISTINCT FROM p_actor_id THEN
     v_code:='sesion_no_pertenece_actor';
   ELSIF v_session_status<>'ABIERTA' OR v_closed_at IS NOT NULL THEN
     v_code:='sesion_cerrada';
   ELSIF v_cash_register_status<>'active' OR v_branch_status<>'active' THEN
     v_code:='caja_o_sucursal_inactiva';
   ELSIF p_fecha<v_opened_at THEN
     v_code:='fecha_anterior_apertura_caja';
   END IF;
 END IF;

 IF v_code IS NULL THEN
   SELECT e.id INTO v_employee_id
   FROM public.empleados e
   WHERE e.organization_id=p_organization_id
     AND e.branch_id=v_branch
     AND e.employment_status='active'
     AND e.activo IS TRUE
     AND (e.app_user_id=p_actor_id OR e.auth_id=p_actor_id)
   ORDER BY e.id LIMIT 1;

   IF v_employee_id IS NULL THEN
     v_code:='empleado_inactivo_otra_sucursal';
   ELSIF NOT EXISTS (
     SELECT 1 FROM public.permissions p
     WHERE p.code='sales.collect' AND p.is_active
   ) THEN
     v_code:='permiso_cobrar_desactivado';
   ELSE
     SELECT EXISTS (
       SELECT 1 FROM public.employee_roles er
       JOIN public.roles r ON r.organization_id=er.organization_id
           AND r.id=er.role_id
       WHERE er.organization_id=p_organization_id AND er.employee_id=v_employee_id
         AND r.code='admin' AND r.status='active'
     ) INTO v_admin;

     SELECT o.allowed INTO v_override
     FROM public.employee_permission_overrides o
     WHERE o.organization_id=p_organization_id AND o.employee_id=v_employee_id
       AND o.permission_code='sales.collect';

     IF NOT v_admin THEN
       IF FOUND THEN
         v_granted:=v_override;
       ELSE
         SELECT EXISTS (
           SELECT 1 FROM public.employee_roles er
           JOIN public.roles r ON r.organization_id=er.organization_id
             AND r.id=er.role_id AND r.status='active'
           JOIN public.role_permissions rp ON rp.organization_id=r.organization_id
             AND rp.role_id=r.id
           WHERE er.organization_id=p_organization_id
             AND er.employee_id=v_employee_id
             AND rp.permission_code='sales.collect'
         ) INTO v_granted;
       END IF;
     ELSE
       v_granted:=true;
     END IF;
     IF NOT COALESCE(v_granted,false) THEN
       v_code:='permiso_cobro_denegado';
     END IF;
   END IF;
 END IF;

 IF v_code IS NULL THEN v_code:='preflight_efectivo_aprobado_sin_registro'; END IF;

 RETURN QUERY SELECT
   v_code='preflight_efectivo_aprobado_sin_registro',v_code,
   CASE WHEN v_code IN ('preflight_efectivo_aprobado_sin_registro','permiso_cobro_denegado','empleado_inactivo_otra_sucursal')
        THEN v_cash_register ELSE NULL::uuid END,
   v_saldo,
   CASE WHEN v_code='preflight_efectivo_aprobado_sin_registro'
        THEN v_saldo-p_monto ELSE NULL::numeric END,
   v_revision;
END;
$fn$;

REVOKE ALL ON FUNCTION private.financial_2c3_cash_preflight(
 uuid,bigint,uuid,uuid,uuid,numeric,timestamptz
) FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION private.financial_2c3_cash_preflight(
 uuid,bigint,uuid,uuid,uuid,numeric,timestamptz
) IS '2C3A solo lectura. Atesta cuenta auditada PEN, moneda, importe, caja abierta del actor y sales.collect. No es una autorizacion de escritura ni RPC cliente.';
