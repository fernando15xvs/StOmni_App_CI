-- 2D-H DEV: fix safe product-deletion evaluation on composite foreign keys.
-- The legacy introspector unnested every local FK component, including
-- organization_id (UUID), then compared it to producto_id (BIGINT), failing
-- with SQLSTATE 42883. Match FK ordinality to referenced productos.id, restrict
-- the local column to int8 and skip the organization_id tenant key.
-- Existing authorization is still performed by public.evaluar_eliminacion_producto_v1.
CREATE OR REPLACE FUNCTION public._legacy_evaluar_eliminacion_producto_v1(p_producto_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_producto public.productos%ROWTYPE;
  v_movimientos_total bigint := 0;
  v_movimientos_apertura bigint := 0;
  v_movimientos_operativos bigint := 0;
  v_stock_total bigint := 0;
  v_filas_stock bigint := 0;
  v_bloqueos jsonb := '[]'::jsonb;
  v_cantidad bigint;
  v_mensaje text;
  v_puede_eliminar boolean;
  r record;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede evaluar la eliminación de productos.';
  END IF;

  IF p_producto_id IS NULL THEN
    RAISE EXCEPTION 'El producto_id es obligatorio.';
  END IF;

  SELECT *
  INTO v_producto
  FROM public.productos
  WHERE id = p_producto_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto % no existe.', p_producto_id;
  END IF;

  SELECT
    COUNT(*),
    COUNT(*) FILTER (
      WHERE UPPER(TRIM(COALESCE(m.tipo, ''))) IN ('ENTRADA', 'INGRESO')
        AND UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(m.observaciones, '')),
            '\s+',
            ' ',
            'g'
          )
        ) IN (
          'APERTURA DE INVENTARIO / STOCK INICIAL',
          'APERTURA DE INVENTARIO',
          'STOCK INICIAL'
        )
        AND m.venta_id IS NULL
        AND COALESCE(m.salida_cant, 0) = 0
    )
  INTO v_movimientos_total, v_movimientos_apertura
  FROM public.inventario_movimientos AS m
  WHERE m.producto_id = p_producto_id;

  v_movimientos_operativos :=
    v_movimientos_total - v_movimientos_apertura;

  SELECT
    COUNT(*),
    COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_filas_stock, v_stock_total
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = p_producto_id;

  IF v_movimientos_operativos > 0 THEN
    v_bloqueos := v_bloqueos || jsonb_build_array(
      jsonb_build_object(
        'tabla', 'inventario_movimientos',
        'cantidad', v_movimientos_operativos,
        'mensaje',
          CASE
            WHEN v_movimientos_operativos = 1
              THEN 'Tiene 1 movimiento operativo de inventario.'
            ELSE format(
              'Tiene %s movimientos operativos de inventario.',
              v_movimientos_operativos
            )
          END
      )
    );
  END IF;

  -- Revisa automáticamente cualquier tabla pública real que contenga
  -- `producto_id`. Se excluyen únicamente las tablas que la eliminación
  -- segura limpia dentro de su propia transacción.
  FOR r IN
    WITH referencias AS (
      -- Columnas convencionales, incluso si no tienen FK.
      SELECT
        c.table_name,
        c.column_name
      FROM information_schema.columns AS c
      JOIN information_schema.tables AS t
        ON t.table_schema = c.table_schema
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND c.column_name = 'producto_id'
        AND t.table_type = 'BASE TABLE'

      UNION

      -- Cualquier FK real que apunte a productos, aunque la columna tenga
      -- otro nombre.
      SELECT
        rel.relname AS table_name,
        att.attname AS column_name
      FROM pg_constraint AS con
      JOIN pg_class AS rel
        ON rel.oid = con.conrelid
      JOIN pg_namespace AS ns
        ON ns.oid = rel.relnamespace
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key_column(attnum,position)
        ON true
      JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS referenced_column(attnum,position)
        ON referenced_column.position = key_column.position
      JOIN pg_attribute AS referenced_attribute
        ON referenced_attribute.attrelid = con.confrelid
       AND referenced_attribute.attnum = referenced_column.attnum
       AND referenced_attribute.attname = 'id'
      JOIN pg_attribute AS att
        ON att.attrelid = con.conrelid
       AND att.attnum = key_column.attnum
       AND att.atttypid = 'pg_catalog.int8'::regtype
      WHERE con.contype = 'f'
        AND con.confrelid = 'public.productos'::regclass
        AND ns.nspname = 'public'
    )
    SELECT DISTINCT
      ref.table_name,
      ref.column_name
    FROM referencias AS ref
    WHERE ref.table_name NOT IN (
      'inventario_almacen',
      'inventario_movimientos',
      'sys_processed_requests'
    )
    ORDER BY ref.table_name, ref.column_name
  LOOP
    -- Composite organization_id UUIDs are not product IDs.
    IF r.column_name='organization_id' THEN
      CONTINUE;
    END IF;
    EXECUTE format(
      'SELECT COUNT(*) FROM public.%I WHERE %I = $1',
      r.table_name,
      r.column_name
    )
    INTO v_cantidad
    USING p_producto_id;

    IF v_cantidad > 0 THEN
      v_mensaje := CASE r.table_name
        WHEN 'detalle_ventas'
          THEN format('Tiene %s detalle(s) de venta.', v_cantidad)
        WHEN 'detalle_cotizaciones'
          THEN format('Tiene %s detalle(s) de cotización.', v_cantidad)
        WHEN 'guias_remision_detalles'
          THEN format('Tiene %s detalle(s) de guía de remisión.', v_cantidad)
        WHEN 'notas_credito_detalles'
          THEN format('Tiene %s detalle(s) de nota de crédito.', v_cantidad)
        WHEN 'transferencias_stock'
          THEN format('Tiene %s traslado(s) de stock.', v_cantidad)
        WHEN 'inventario_operaciones_idempotentes'
          THEN format(
            'Tiene %s operación(es) de inventario registrada(s).',
            v_cantidad
          )
        ELSE format(
          'Tiene %s referencia(s) en la tabla %s.',
          v_cantidad,
          r.table_name
        )
      END;

      v_bloqueos := v_bloqueos || jsonb_build_array(
        jsonb_build_object(
          'tabla', r.table_name,
          'columna', r.column_name,
          'cantidad', v_cantidad,
          'mensaje', v_mensaje
        )
      );
    END IF;
  END LOOP;

  v_puede_eliminar :=
    v_movimientos_operativos = 0
    AND jsonb_array_length(v_bloqueos) = 0;

  RETURN jsonb_build_object(
    'success', true,
    'producto_id', v_producto.id,
    'producto_nombre', v_producto.nombre,
    'producto_activo', COALESCE(v_producto.activo, true),
    'imagen_path', v_producto.imagen_path,
    'movimientos_total', v_movimientos_total,
    'movimientos_apertura', v_movimientos_apertura,
    'movimientos_operativos', v_movimientos_operativos,
    'filas_stock', v_filas_stock,
    'stock_total', v_stock_total,
    'solo_apertura',
      v_movimientos_total = v_movimientos_apertura,
    'puede_actualizar_apertura',
      v_puede_eliminar AND v_movimientos_apertura > 0,
    'puede_eliminar', v_puede_eliminar,
    'accion_permitida',
      CASE WHEN v_puede_eliminar THEN 'eliminar' ELSE 'desactivar' END,
    'bloqueos', v_bloqueos
  );
END;
$function$;
