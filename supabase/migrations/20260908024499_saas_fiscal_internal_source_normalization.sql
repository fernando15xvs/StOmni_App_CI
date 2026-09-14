-- Compatibilidad de formato para los parches internos de F3.7.
-- El snapshot remoto puede contener las RPC tributarias internas con sentencias
-- compactadas en una sola linea. La migracion siguiente endurece esas funciones
-- mediante anclas textuales multilínea. Aqui solo normalizamos whitespace; no se
-- cambia ninguna condicion de negocio, plazo tributario ni permiso.
BEGIN;

DO $normalize_internal_fiscal_sources$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_normalized text;
BEGIN
  -- Claim tributario: actor, target e INSERT de intento pueden venir compactados.
  v_sig := 'public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)'::regprocedure;
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_normalized := replace(replace(v_def,E'\r\n',E'\n'),E'\r',E'\n');

  v_normalized := replace(
    v_normalized,
    E'WHERE e.auth_id = p_usuario_id AND COALESCE(e.activo, false) = true AND e.rol = ''admin''',
    E'WHERE e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true\n      AND e.rol = ''admin'''
  );

  v_normalized := replace(
    v_normalized,
    E'FROM public.procesos_tributarios WHERE id = p_proceso_id FOR UPDATE;',
    E'FROM public.procesos_tributarios\n  WHERE id = p_proceso_id\n  FOR UPDATE;'
  );

  v_normalized := replace(
    v_normalized,
    E'INSERT INTO public.procesos_tributarios_intentos(proceso_id, numero_intento, accion, resultado, usuario_id, lock_token, fecha_inicio)\n  VALUES (p_proceso_id, v_numero, v_accion, ''procesando'', p_usuario_id, v_token, now())',
    E'INSERT INTO public.procesos_tributarios_intentos(\n    proceso_id, numero_intento, accion, resultado,\n    usuario_id, lock_token, fecha_inicio\n  ) VALUES (\n    p_proceso_id, v_numero, v_accion, ''procesando'',\n    p_usuario_id, v_token, now()\n  )'
  );

  IF v_normalized IS DISTINCT FROM v_def THEN
    EXECUTE v_normalized;
  END IF;

  -- Finalizador tributario: el SELECT objetivo puede venir completamente en una linea.
  v_sig := 'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)'::regprocedure;
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_normalized := replace(replace(v_def,E'\r\n',E'\n'),E'\r',E'\n');

  v_normalized := replace(
    v_normalized,
    E'FROM public.procesos_tributarios WHERE id = p_proceso_id FOR UPDATE;',
    E'FROM public.procesos_tributarios\n  WHERE id = p_proceso_id\n  FOR UPDATE;'
  );

  IF v_normalized IS DISTINCT FROM v_def THEN
    EXECUTE v_normalized;
  END IF;
END;
$normalize_internal_fiscal_sources$;

COMMIT;
