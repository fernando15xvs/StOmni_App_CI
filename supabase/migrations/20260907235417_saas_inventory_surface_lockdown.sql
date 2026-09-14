-- Fase 3.3/3.4 SaaS: cierre de superficie RPC legacy de catálogo/inventario.
-- Sólo los entrypoints tenant-aware vigentes quedan ejecutables por authenticated.
BEGIN;

-- Las implementaciones históricas de evaluación/eliminación contienen lógica útil,
-- pero no validaban tenant al entrar. Se conservan como implementación privada de
-- transición y se exponen únicamente detrás de wrappers tenant-aware.
--
-- El laboratorio de esquema puede partir de un snapshot donde las funciones legacy
-- ya existen. En ese caso no debemos intentar renombrarlas una segunda vez.
DO $$
BEGIN
  IF to_regprocedure('public._legacy_evaluar_eliminacion_producto_v1(bigint)') IS NULL THEN
    IF to_regprocedure('public.evaluar_eliminacion_producto_v1(bigint)') IS NULL THEN
      RAISE EXCEPTION 'Missing evaluar_eliminacion_producto_v1(bigint) legacy source';
    END IF;

    ALTER FUNCTION public.evaluar_eliminacion_producto_v1(bigint)
      RENAME TO _legacy_evaluar_eliminacion_producto_v1;
  END IF;
END;
$$;

DO $$
BEGIN
  IF to_regprocedure('public._legacy_eliminar_producto_seguro_v1(bigint)') IS NULL THEN
    IF to_regprocedure('public.eliminar_producto_seguro_v1(bigint)') IS NULL THEN
      RAISE EXCEPTION 'Missing eliminar_producto_seguro_v1(bigint) legacy source';
    END IF;

    ALTER FUNCTION public.eliminar_producto_seguro_v1(bigint)
      RENAME TO _legacy_eliminar_producto_seguro_v1;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._legacy_evaluar_eliminacion_producto_v1(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._legacy_eliminar_producto_seguro_v1(bigint)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.evaluar_eliminacion_producto_v1(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Administrator permission required';
  END IF;

  PERFORM private.assert_product_in_current_organization(p_producto_id);
  RETURN public._legacy_evaluar_eliminacion_producto_v1(p_producto_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_producto_seguro_v1(p_producto_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Administrator permission required';
  END IF;

  PERFORM private.assert_product_in_current_organization(p_producto_id);
  RETURN public._legacy_eliminar_producto_seguro_v1(p_producto_id);
END;
$$;

REVOKE ALL ON FUNCTION public.evaluar_eliminacion_producto_v1(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.eliminar_producto_seguro_v1(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evaluar_eliminacion_producto_v1(bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_producto_seguro_v1(bigint)
  TO authenticated;

-- Entry points internos/obsoletos: no deben quedar invocables desde Data API.
REVOKE ALL ON FUNCTION public.ajustar_stock_y_kardex(
  bigint,bigint,integer,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric,text
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_v2(
  uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.registrar_merma_v2(
  uuid,bigint,bigint,integer,text,timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v2(
  uuid,bigint,bigint,numeric,text,timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v3(
  uuid,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.trasladar_stock_v2(
  uuid,bigint,bigint,bigint,integer,text,timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v2(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v3(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC, anon, authenticated;

-- Allowlist explícita de RPC cliente vigentes de catálogo/inventario.
REVOKE ALL ON FUNCTION public.ajustar_stock_scaled_v2(
  bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ajustar_stock_scaled_v2(
  bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric
) TO authenticated;

REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(
  uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(
  uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric
) TO authenticated;

REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v4(
  uuid,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v4(
  uuid,bigint,bigint,numeric,text,timestamptz,jsonb
) TO authenticated;

REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v4(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v4(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb
) TO authenticated;

REVOKE ALL ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_producto_con_stock(uuid,jsonb,jsonb)
  TO authenticated;

REVOKE ALL ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)
  TO authenticated;

REVOKE ALL ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_service_v1(bigint,text,text,text,numeric,numeric)
  TO authenticated;

REVOKE ALL ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) TO authenticated;

COMMIT;
