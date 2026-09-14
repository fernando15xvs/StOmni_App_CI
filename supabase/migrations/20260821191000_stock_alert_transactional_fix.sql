-- Corrige falsas alertas de stock bajo durante traslados.
--
-- Problema anterior:
-- el trigger se ejecutaba por cada fila de inventario_almacen. En un traslado
-- primero se descontaba el origen y, antes de sumar el destino, el trigger veia
-- un stock total transitoriamente menor y podia notificar un faltante inexistente.
--
-- Solucion:
-- 1) acumular por producto el delta TOTAL de la transaccion;
-- 2) evaluar una sola vez al final de la transaccion con un constraint trigger
--    DEFERRABLE INITIALLY DEFERRED;
-- 3) leer la App API key de OneSignal desde Supabase Vault;
-- 4) usar la API moderna de OneSignal (`api.onesignal.com`) con
--    `Authorization: Key <APP_API_KEY>`.
--
-- Requisito operativo antes de aplicar en un entorno real:
-- crear/rotar en Vault el secreto con nombre `onesignal_rest_api_key`.
-- Ejemplo (NO versionar el valor real):
-- SELECT vault.create_secret('<APP_API_KEY_ROTADA>', 'onesignal_rest_api_key');

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS public.stock_alert_tx_context (
  txid bigint NOT NULL,
  producto_id bigint NOT NULL REFERENCES public.productos(id) ON DELETE CASCADE,
  delta_total bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (txid, producto_id)
);

ALTER TABLE public.stock_alert_tx_context ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.stock_alert_tx_context FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._stock_alert_acumular_tx()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF NEW.cantidad IS NOT DISTINCT FROM OLD.cantidad THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.stock_alert_tx_context (
    txid,
    producto_id,
    delta_total
  )
  VALUES (
    txid_current(),
    NEW.producto_id,
    COALESCE(OLD.cantidad, 0) - COALESCE(NEW.cantidad, 0)
  )
  ON CONFLICT (txid, producto_id)
  DO UPDATE SET
    delta_total = public.stock_alert_tx_context.delta_total + EXCLUDED.delta_total;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notificar_stock_bajo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_delta_total bigint;
  v_stock_minimo integer;
  v_stock_total_nuevo bigint;
  v_stock_total_viejo bigint;
  v_nombre_producto text;
  v_tipo_venta text;
  v_cantidad_por_caja integer;
  v_texto_stock text;
  v_cajas bigint;
  v_sueltos bigint;
  v_onesignal_rest_api_key text;
  v_request_id bigint;
  v_cuerpo_json jsonb;
BEGIN
  -- Solo la primera ejecucion diferida por producto consume el acumulador.
  -- Si una transaccion toco varias filas del mismo producto, las siguientes
  -- ejecuciones diferidas no encuentran contexto y terminan sin duplicar aviso.
  DELETE FROM public.stock_alert_tx_context
  WHERE txid = txid_current()
    AND producto_id = NEW.producto_id
  RETURNING delta_total INTO v_delta_total;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT
    p.stock_minimo,
    p.nombre,
    COALESCE(UPPER(p.tipo_venta), ''),
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
  INTO
    v_stock_minimo,
    v_nombre_producto,
    v_tipo_venta,
    v_cantidad_por_caja
  FROM public.productos AS p
  WHERE p.id = NEW.producto_id;

  IF NOT FOUND OR v_stock_minimo IS NULL THEN
    RETURN NEW;
  END IF;

  -- A estas alturas todas las mutaciones de inventario de la transaccion ya
  -- ocurrieron. Este es el total FINAL real, no un estado intermedio.
  SELECT COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_stock_total_nuevo
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = NEW.producto_id;

  -- delta_total = SUM(OLD.cantidad - NEW.cantidad).
  -- Por tanto: stock_anterior = stock_final + delta_total.
  v_stock_total_viejo := v_stock_total_nuevo + COALESCE(v_delta_total, 0);

  -- Anti-spam transaccional: solo notificar cuando el TOTAL cruza desde arriba
  -- del minimo hacia el minimo o por debajo. Un traslado puro tiene delta 0,
  -- por lo que 13 -> 13 nunca dispara una alerta aunque el origen pase 12 -> 8.
  IF NOT (
    v_stock_total_viejo > v_stock_minimo
    AND v_stock_total_nuevo <= v_stock_minimo
  ) THEN
    RETURN NEW;
  END IF;

  IF v_tipo_venta IN ('CAJA_PAQUETES', 'CAJA+PAQUETES', 'CAJA + PAQUETES') THEN
    IF v_cantidad_por_caja <= 1 THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
    ELSE
      v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
      v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
      IF v_cajas = 0 THEN
        v_texto_stock := v_sueltos ||
          CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
      ELSIF v_sueltos = 0 THEN
        v_texto_stock := v_cajas ||
          CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
      ELSE
        v_texto_stock :=
          v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
          v_sueltos || CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
      END IF;
    END IF;
  ELSIF v_tipo_venta IN (
    'CAJA_UNIDADES', 'CAJA+UNIDADES', 'CAJA + UNIDADES',
    'AMBOS', 'CAJA_UNIDAD', 'CAJAS_UNIDADES'
  ) THEN
    IF v_cantidad_por_caja <= 1 THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
    ELSE
      v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
      v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
      IF v_cajas = 0 THEN
        v_texto_stock := v_sueltos ||
          CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
      ELSIF v_sueltos = 0 THEN
        v_texto_stock := v_cajas ||
          CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
      ELSE
        v_texto_stock :=
          v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
          v_sueltos || CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
      END IF;
    END IF;
  ELSIF v_tipo_venta IN ('PAQUETES', 'PAQUETE') THEN
    v_texto_stock := v_stock_total_nuevo ||
      CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
  ELSIF v_tipo_venta IN ('CAJA', 'SOLO_CAJAS') THEN
    v_texto_stock := v_stock_total_nuevo ||
      CASE WHEN v_stock_total_nuevo = 1 THEN ' caja' ELSE ' cajas' END;
  ELSE
    v_texto_stock := v_stock_total_nuevo ||
      CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
  END IF;

  -- El secreto no debe vivir en Git. Si Vault no esta configurado, una alerta
  -- nunca debe hacer fallar la venta/traslado que origino el cambio de stock.
  BEGIN
    SELECT ds.decrypted_secret
    INTO v_onesignal_rest_api_key
    FROM vault.decrypted_secrets AS ds
    WHERE ds.name = 'onesignal_rest_api_key'
    ORDER BY ds.created_at DESC
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE WARNING 'OneSignal Vault no esta disponible; se omite alerta de stock bajo.';
      RETURN NEW;
  END;

  IF NULLIF(TRIM(v_onesignal_rest_api_key), '') IS NULL THEN
    RAISE WARNING 'Falta el secreto onesignal_rest_api_key en Vault; se omite alerta de stock bajo.';
    RETURN NEW;
  END IF;

  v_cuerpo_json := jsonb_build_object(
    'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
    'target_channel', 'push',
    'included_segments', jsonb_build_array('All'),
    'headings', jsonb_build_object('en', '⚠️ Alerta de Stock Bajo'),
    'contents', jsonb_build_object(
      'en',
      'El producto "' || v_nombre_producto ||
      '" está por agotarse. Quedan solo ' || v_texto_stock || ' en total.'
    )
  );

  BEGIN
    SELECT net.http_post(
      url := 'https://api.onesignal.com/notifications',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Key ' || v_onesignal_rest_api_key
      ),
      body := v_cuerpo_json
    )
    INTO v_request_id;
  EXCEPTION
    WHEN OTHERS THEN
      -- La notificacion es secundaria: nunca debe revertir stock/Kardex/venta.
      RAISE WARNING 'No se pudo encolar la alerta de stock bajo para producto %.', NEW.producto_id;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trigger_revisar_stock ON public.inventario_almacen;
DROP TRIGGER IF EXISTS trigger_stock_alert_acumular_tx ON public.inventario_almacen;
DROP TRIGGER IF EXISTS trigger_stock_alert_evaluar_tx ON public.inventario_almacen;

CREATE TRIGGER trigger_stock_alert_acumular_tx
AFTER UPDATE OF cantidad ON public.inventario_almacen
FOR EACH ROW
WHEN (OLD.cantidad IS DISTINCT FROM NEW.cantidad)
EXECUTE FUNCTION public._stock_alert_acumular_tx();

CREATE CONSTRAINT TRIGGER trigger_stock_alert_evaluar_tx
AFTER UPDATE ON public.inventario_almacen
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (OLD.cantidad IS DISTINCT FROM NEW.cantidad)
EXECUTE FUNCTION public.notificar_stock_bajo();

REVOKE ALL ON FUNCTION public._stock_alert_acumular_tx() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notificar_stock_bajo() FROM PUBLIC, anon, authenticated;
