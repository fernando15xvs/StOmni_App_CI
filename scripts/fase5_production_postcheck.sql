-- StOmni / Fase 5 - Postcheck de produccion (SOLO LECTURA)
-- Ejecutar inmediatamente despues de un rollout autorizado de las 4 migraciones.
-- Todas las columnas *_ok deben resultar TRUE y las colecciones de errores vacias.

BEGIN TRANSACTION READ ONLY;

SELECT
  to_regclass('public.pagos_deuda_requests') IS NOT NULL AS pagos_deuda_requests_ok,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='pagos_venta' AND column_name='request_id'
  ) AS pagos_venta_request_id_ok,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='pagos_gasto' AND column_name='request_id'
  ) AS pagos_gasto_request_id_ok,
  to_regprocedure('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)') IS NOT NULL AS deuda_v2_ok,
  to_regprocedure('public.desactivar_almacen_seguro_v1(bigint)') IS NOT NULL AS desactivar_almacen_v1_ok,
  to_regprocedure('public.reactivar_almacen_seguro_v1(bigint)') IS NOT NULL AS reactivar_almacen_v1_ok,
  to_regprocedure('public.eliminar_pago_gasto_v1(bigint,bigint)') IS NOT NULL AS eliminar_pago_gasto_v1_ok,
  to_regprocedure('public.eliminar_gasto_v1(bigint)') IS NOT NULL AS eliminar_gasto_v1_ok,
  to_regprocedure('public.tributario_finalizar_proceso(bigint)') IS NULL AS tributario_legacy_removed_ok,
  to_regprocedure('public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)') IS NOT NULL AS tributario_uuid_ok;

-- RLS/grants endurecidos.
SELECT
  NOT has_table_privilege('anon', 'public.clientes', 'SELECT') AS clientes_anon_select_blocked_ok,
  has_table_privilege('authenticated', 'public.clientes', 'SELECT') AS clientes_authenticated_select_ok,
  has_table_privilege('authenticated', 'public.clientes', 'INSERT') AS clientes_authenticated_insert_ok,
  has_table_privilege('authenticated', 'public.clientes', 'UPDATE') AS clientes_authenticated_update_ok,
  has_table_privilege('authenticated', 'public.clientes', 'DELETE') AS clientes_authenticated_delete_ok,
  NOT has_table_privilege('anon', 'public.transferencias_stock', 'SELECT') AS transferencias_anon_select_blocked_ok,
  has_table_privilege('authenticated', 'public.transferencias_stock', 'SELECT') AS transferencias_authenticated_select_ok,
  NOT has_table_privilege('authenticated', 'public.transferencias_stock', 'INSERT') AS transferencias_authenticated_insert_blocked_ok,
  NOT has_table_privilege('authenticated', 'public.transferencias_stock', 'UPDATE') AS transferencias_authenticated_update_blocked_ok,
  NOT has_table_privilege('authenticated', 'public.transferencias_stock', 'DELETE') AS transferencias_authenticated_delete_blocked_ok,
  NOT has_table_privilege('authenticated', 'public.inventario_operaciones_idempotentes', 'SELECT') AS inventario_idempotencia_direct_select_blocked_ok,
  NOT has_table_privilege('authenticated', 'public.sys_processed_requests', 'SELECT') AS processed_requests_direct_select_blocked_ok;

SELECT tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN ('clientes','transferencias_stock')
ORDER BY tablename, policyname;

-- Almacenes: no debe quedar DELETE directo authenticated y deben existir ambos triggers.
SELECT
  NOT has_table_privilege('authenticated', 'public.almacenes', 'DELETE') AS almacenes_delete_blocked_ok,
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.almacenes'::regclass
      AND tgname='trg_validar_desactivacion_almacen_v1'
      AND NOT tgisinternal
  ) AS almacen_deactivation_trigger_ok,
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.inventario_almacen'::regclass
      AND tgname='trg_validar_stock_en_almacen_activo_v1'
      AND NOT tgisinternal
  ) AS active_warehouse_stock_trigger_ok;

-- El duplicado UNIQUE debe quedar reducido a uno.
SELECT count(*) = 1 AS inventario_unique_single_ok
FROM pg_constraint c
WHERE c.conrelid='public.inventario_almacen'::regclass
  AND c.contype='u'
  AND pg_get_constraintdef(c.oid)='UNIQUE (producto_id, almacen_id)';

-- No debe aparecer ningun almacen inactivo con stock.
SELECT a.id, a.nombre, COALESCE(sum(abs(COALESCE(ia.cantidad,0))),0) AS stock_abs
FROM public.almacenes a
LEFT JOIN public.inventario_almacen ia ON ia.almacen_id=a.id
WHERE COALESCE(a.activo,false)=false
GROUP BY a.id,a.nombre
HAVING COALESCE(sum(abs(COALESCE(ia.cantidad,0))),0) <> 0
ORDER BY a.id;

-- Roles siguen canonicos.
SELECT count(*) = 0 AS roles_canonicos_ok
FROM public.empleados
WHERE rol IS NULL OR rol NOT IN ('admin','operador');

COMMIT;
