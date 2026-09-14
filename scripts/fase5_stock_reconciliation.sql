-- StOmni - Fase 5
-- Conciliacion READ-ONLY entre inventario_almacen y Kardex.
--
-- IMPORTANTE:
-- - No contiene INSERT/UPDATE/DELETE ni corrige datos automaticamente.
-- - El orden de auditoria es por inventario_movimientos.id DESC, no por fecha.
--   `fecha` es fecha de negocio y puede ser retroactiva o no reflejar el orden
--   real en que PostgreSQL aplico las operaciones.
-- - El ultimo `saldo` por id debe coincidir con inventario_almacen.cantidad.

WITH latest AS (
  SELECT DISTINCT ON (m.producto_id, m.almacen_id)
    m.producto_id,
    m.almacen_id,
    m.id AS movimiento_id,
    m.fecha,
    m.tipo,
    m.saldo,
    m.observaciones,
    m.request_id
  FROM public.inventario_movimientos AS m
  WHERE m.producto_id IS NOT NULL
    AND m.almacen_id IS NOT NULL
  ORDER BY m.producto_id, m.almacen_id, m.id DESC
), compared AS (
  SELECT
    ia.producto_id,
    ia.almacen_id,
    ia.cantidad AS stock_actual,
    l.movimiento_id,
    l.fecha AS ultima_fecha_negocio,
    l.tipo AS ultimo_tipo,
    l.saldo AS ultimo_saldo_kardex,
    l.observaciones,
    l.request_id,
    CASE
      WHEN l.movimiento_id IS NULL THEN 'sin_kardex'
      WHEN l.saldo IS DISTINCT FROM ia.cantidad::numeric THEN 'diferencia'
      ELSE 'ok'
    END AS estado
  FROM public.inventario_almacen AS ia
  LEFT JOIN latest AS l
    ON l.producto_id = ia.producto_id
   AND l.almacen_id = ia.almacen_id
)
SELECT
  c.producto_id,
  p.codigo,
  p.nombre AS producto,
  c.almacen_id,
  a.nombre AS almacen,
  c.stock_actual,
  c.ultimo_saldo_kardex,
  c.stock_actual::numeric - c.ultimo_saldo_kardex AS diferencia,
  c.movimiento_id,
  c.ultima_fecha_negocio,
  c.ultimo_tipo,
  c.observaciones,
  c.request_id,
  p.permitir_sin_stock,
  c.estado
FROM compared AS c
JOIN public.productos AS p ON p.id = c.producto_id
JOIN public.almacenes AS a ON a.id = c.almacen_id
WHERE c.estado <> 'ok'
   OR (
     c.stock_actual < 0
     AND COALESCE(p.permitir_sin_stock, false) = false
   )
ORDER BY c.estado, p.nombre, a.nombre;

-- Resumen independiente para smoke/auditoria.
WITH latest AS (
  SELECT DISTINCT ON (m.producto_id, m.almacen_id)
    m.producto_id,
    m.almacen_id,
    m.id AS movimiento_id,
    m.saldo
  FROM public.inventario_movimientos AS m
  WHERE m.producto_id IS NOT NULL
    AND m.almacen_id IS NOT NULL
  ORDER BY m.producto_id, m.almacen_id, m.id DESC
), compared AS (
  SELECT
    ia.producto_id,
    ia.almacen_id,
    ia.cantidad AS stock_actual,
    p.permitir_sin_stock,
    l.movimiento_id,
    l.saldo AS ultimo_saldo,
    CASE
      WHEN l.movimiento_id IS NULL THEN 'sin_kardex'
      WHEN l.saldo IS DISTINCT FROM ia.cantidad::numeric THEN 'diferencia'
      ELSE 'ok'
    END AS estado
  FROM public.inventario_almacen AS ia
  JOIN public.productos AS p ON p.id = ia.producto_id
  LEFT JOIN latest AS l
    ON l.producto_id = ia.producto_id
   AND l.almacen_id = ia.almacen_id
)
SELECT
  count(*) AS filas_inventario,
  count(*) FILTER (WHERE estado = 'ok') AS conciliadas,
  count(*) FILTER (WHERE estado = 'diferencia') AS diferencias_kardex,
  count(*) FILTER (WHERE estado = 'sin_kardex') AS sin_kardex,
  count(*) FILTER (WHERE stock_actual < 0) AS negativos_totales,
  count(*) FILTER (
    WHERE stock_actual < 0
      AND COALESCE(permitir_sin_stock, false) = false
  ) AS negativos_no_permitidos
FROM compared;
