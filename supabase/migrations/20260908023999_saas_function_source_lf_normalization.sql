-- Compatibilidad cross-platform para los parches textuales de F3.7.
-- Algunas funciones historicas pueden haber sido creadas con CRLF (Windows) o
-- haber sido formateadas de manera compacta en el proyecto remoto. pg_get_functiondef()
-- conserva esas diferencias dentro del cuerpo, mientras que la migracion F3.7
-- compara fragmentos canonicos. Normalizamos solamente el texto fuente de las
-- RPC que F3.7 va a endurecer; CREATE OR REPLACE conserva firma, owner y
-- privilegios y no altera su logica.
BEGIN;

DO $normalize_fiscal_function_sources$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_normalized text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure,
    'public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure,
    'public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure,
    'public.obtener_disponibilidad_nota_credito_v2(uuid)'::regprocedure,
    'public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)'::regprocedure,
    'public.guardar_guia_remision_v3(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)'::regprocedure,
    'public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure,
    'public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure,
    'public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure,
    'public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure
  ] LOOP
    SELECT pg_get_functiondef(v_sig) INTO v_def;
    v_normalized := replace(replace(v_def,E'\r\n',E'\n'),E'\r',E'\n');

    -- El snapshot remoto puede contener una version mas reciente de la RPC de
    -- baja tributaria con exactamente la misma logica, pero con sentencias
    -- compactadas en una linea. Expandimos solo el whitespace que los parches
    -- F3.7 usan como ancla; no se modifica ninguna condicion de negocio.
    IF v_sig = 'public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure THEN
      v_normalized := replace(
        v_normalized,
        E'FROM public.solicitudes_baja_tributaria WHERE request_id = p_request_id;',
        E'FROM public.solicitudes_baja_tributaria\n  WHERE request_id = p_request_id;'
      );
      v_normalized := replace(
        v_normalized,
        E'FROM public.comprobantes_electronicos ce\n    WHERE ce.id = p_origen_id FOR UPDATE;',
        E'FROM public.comprobantes_electronicos ce\n    WHERE ce.id = p_origen_id\n    FOR UPDATE;'
      );
      v_normalized := replace(
        v_normalized,
        E'FROM public.notas_credito nc\n    WHERE nc.id = p_origen_id FOR UPDATE;',
        E'FROM public.notas_credito nc\n    WHERE nc.id = p_origen_id\n    FOR UPDATE;'
      );
    END IF;

    IF v_normalized IS DISTINCT FROM v_def THEN
      EXECUTE v_normalized;
    END IF;
  END LOOP;
END;
$normalize_fiscal_function_sources$;

COMMIT;
