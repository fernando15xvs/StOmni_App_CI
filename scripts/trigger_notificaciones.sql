-- Instalador manual de alertas de stock bajo y producto agotado.
-- Fuente versionada equivalente:
-- supabase/migration_sources/pre_bootstrap/20260821191000_stock_alert_transactional_fix.sql
--
-- IMPORTANTE:
-- 1. La alerta se evalua por el delta TOTAL de la transaccion. Un traslado
--    13 -> 13 no debe alertar aunque el almacen origen baje temporalmente.
-- 2. Se distinguen dos eventos anti-spam:
--      STOCK_BAJO: cruza el minimo y queda stock > 0.
--      AGOTADO: cruza desde stock positivo a 0 o menos.
--    Un salto directo 13 -> 0 envia solo AGOTADO.
-- 3. La App API key de OneSignal NO debe escribirse en este archivo.
--    Configure en Supabase Vault un secreto llamado `onesignal_rest_api_key`.
--    Ejemplo (reemplace el placeholder solo en su entorno seguro):
--    SELECT vault.create_secret('<APP_API_KEY_ROTADA>', 'onesignal_rest_api_key');
-- 4. La API moderna usa https://api.onesignal.com y Authorization: Key.
-- 5. Este SQL se mantiene en ASCII; los simbolos Unicode se construyen con
--    chr(...) para evitar mojibake al copiarlo desde PowerShell.

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

  INSERT INTO public.stock_alert_tx_context (txid, producto_id, delta_total)
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
  v_tipo_alerta text;
  v_texto_stock text;
  v_cajas bigint;
  v_sueltos bigint;
  v_onesignal_rest_api_key text;
  v_request_id bigint;
  v_cuerpo_json jsonb;
BEGIN
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
    COALESCE(p.tipo_venta, ''),
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
  INTO
    v_stock_minimo,
    v_nombre_producto,
    v_tipo_venta,
    v_cantidad_por_caja
  FROM public.productos AS p
  WHERE p.id = NEW.producto_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_stock_total_nuevo
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = NEW.producto_id;

  v_stock_total_viejo := v_stock_total_nuevo + COALESCE(v_delta_total, 0);

  IF v_stock_total_viejo > 0
     AND v_stock_total_nuevo <= 0 THEN
    v_tipo_alerta := 'agotado';
  ELSIF v_stock_minimo IS NOT NULL
     AND v_stock_total_viejo > v_stock_minimo
     AND v_stock_total_nuevo <= v_stock_minimo
     AND v_stock_total_nuevo > 0 THEN
    v_tipo_alerta := 'stock_bajo';
  ELSE
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'stock_bajo' THEN
    IF v_tipo_venta = 'CAJA_PAQUETES' THEN
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
    ELSIF v_tipo_venta = 'CAJA_UNIDADES' THEN
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
    ELSIF v_tipo_venta = 'PAQUETE' THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
    ELSIF v_tipo_venta = 'CAJA' THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' caja' ELSE ' cajas' END;
    ELSE
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
    END IF;
  END IF;

  BEGIN
    SELECT ds.decrypted_secret
    INTO v_onesignal_rest_api_key
    FROM vault.decrypted_secrets AS ds
    WHERE ds.name = 'onesignal_rest_api_key'
    ORDER BY ds.created_at DESC
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE WARNING 'OneSignal Vault no esta disponible; se omite alerta de stock.';
      RETURN NEW;
  END;

  IF NULLIF(TRIM(v_onesignal_rest_api_key), '') IS NULL THEN
    RAISE WARNING 'Falta el secreto onesignal_rest_api_key en Vault; se omite alerta de stock.';
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'agotado' THEN
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(128680) || ' ' || chr(161) || 'Producto Agotado!'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" se ha quedado sin stock (0). ' || chr(161) || 'Revisar inventario!'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'agotado',
        'producto_id', NEW.producto_id
      )
    );
  ELSE
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(9888) || chr(65039) || ' Alerta de Stock Bajo'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" est' || chr(225) || ' por agotarse. Quedan solo ' ||
        v_texto_stock || ' en total.'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'stock_bajo',
        'producto_id', NEW.producto_id
      )
    );
  END IF;

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
      RAISE WARNING 'No se pudo encolar la alerta de stock para producto %.', NEW.producto_id;
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
