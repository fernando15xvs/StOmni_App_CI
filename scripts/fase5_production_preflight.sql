-- StOmni / Fase 5 - Preflight de produccion (SOLO LECTURA)
-- Ejecutar inmediatamente antes de un rollout autorizado.
-- No contiene INSERT/UPDATE/DELETE/DDL ni altera migration history.

BEGIN TRANSACTION READ ONLY;

SELECT
  current_database() AS database_name,
  current_setting('server_version') AS postgres_version,
  now() AS checked_at;

-- Roles tecnicos validos y usuarios operativos.
SELECT
  count(*) FILTER (WHERE activo IS TRUE AND rol = 'admin' AND auth_id IS NOT NULL) AS active_admins,
  count(*) FILTER (WHERE activo IS TRUE AND rol = 'operador' AND auth_id IS NOT NULL) AS active_operators,
  count(*) FILTER (WHERE rol IS NULL OR rol NOT IN ('admin', 'operador')) AS legacy_or_invalid_roles
FROM public.empleados;

-- La migracion de almacenes debe entrar sin datos historicos incompatibles.
SELECT
  a.id AS almacen_id,
  a.nombre,
  COALESCE(sum(abs(COALESCE(ia.cantidad, 0))), 0) AS stock_abs
FROM public.almacenes a
LEFT JOIN public.inventario_almacen ia ON ia.almacen_id = a.id
WHERE COALESCE(a.activo, false) = false
GROUP BY a.id, a.nombre
HAVING COALESCE(sum(abs(COALESCE(ia.cantidad, 0))), 0) <> 0
ORDER BY a.id;

-- Las cuatro migraciones Fase 5 deben seguir pendientes antes del rollout.
SELECT
  to_regclass('public.pagos_deuda_requests') IS NOT NULL AS pagos_deuda_requests_exists,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='pagos_venta' AND column_name='request_id'
  ) AS pagos_venta_request_id_exists,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='pagos_gasto' AND column_name='request_id'
  ) AS pagos_gasto_request_id_exists,
  to_regprocedure('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)') IS NOT NULL AS deuda_v2_exists,
  to_regprocedure('public.desactivar_almacen_seguro_v1(bigint)') IS NOT NULL AS desactivar_almacen_v1_exists,
  to_regprocedure('public.reactivar_almacen_seguro_v1(bigint)') IS NOT NULL AS reactivar_almacen_v1_exists,
  to_regprocedure('public.eliminar_pago_gasto_v1(bigint,bigint)') IS NOT NULL AS eliminar_pago_gasto_v1_exists,
  to_regprocedure('public.eliminar_gasto_v1(bigint)') IS NOT NULL AS eliminar_gasto_v1_exists;

-- El overload tributario roto debe existir antes del hardening y el actual UUID
-- debe existir siempre.
SELECT
  to_regprocedure('public.tributario_finalizar_proceso(bigint)') IS NOT NULL AS legacy_bigint_exists,
  to_regprocedure('public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)') IS NOT NULL AS current_uuid_exists;

-- Confirmar la FK usada por eliminar_gasto_v1.
SELECT
  c.conname,
  pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
WHERE c.conrelid = 'public.pagos_gasto'::regclass
  AND c.contype = 'f'
  AND pg_get_constraintdef(c.oid) ILIKE '%gasto_id%REFERENCES gastos(id)%';

-- Duplicado UNIQUE que la migracion advisor retira.
SELECT
  c.conname,
  pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
WHERE c.conrelid = 'public.inventario_almacen'::regclass
  AND c.contype = 'u'
  AND pg_get_constraintdef(c.oid) = 'UNIQUE (producto_id, almacen_id)'
ORDER BY c.conname;

-- Caja abierta no bloquea la migracion, pero se registra para smoke posterior.
SELECT id, estado, fecha_apertura, monto_apertura
FROM public.sesiones_caja
WHERE estado = 'ABIERTA'
ORDER BY fecha_apertura DESC;

COMMIT;
