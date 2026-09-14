-- F2.3 transitional hardening for surfaces intentionally deferred to Block 4.
-- Caja belongs to F4.3 and employee payroll/cash handling to F4.4/F4.3.
-- Until those tables receive tenant ownership, no RPC may expose or mutate
-- cross-tenant operational state.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_estado_caja_chica()
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
BEGIN
  RETURN json_build_object(
    'abierta', false,
    'disponible', false,
    'organization_id', v_org,
    'motivo', 'Caja Chica permanece deshabilitada hasta F4.3'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_estado_caja_chica()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_estado_caja_chica()
  TO authenticated;

-- Esta RPC escribe pagos_empleados y puede afectar Caja. Ambas superficies siguen
-- sin ownership tenant final; mantenerla ejecutable por authenticated sería un
-- bypass de la secuencia del roadmap.
REVOKE ALL ON FUNCTION public.registrar_pago_empleado_mixto(
  bigint,
  text,
  timestamptz,
  jsonb
) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.get_estado_caja_chica() IS
  'Fail-closed SaaS placeholder hasta F4.3. No consulta sesiones_caja ni movimientos.';
COMMENT ON FUNCTION public.registrar_pago_empleado_mixto(bigint,text,timestamptz,jsonb) IS
  'RPC diferida: sin EXECUTE cliente hasta tenantificar pagos_empleados y Caja en F4.3/F4.4.';

COMMIT;
