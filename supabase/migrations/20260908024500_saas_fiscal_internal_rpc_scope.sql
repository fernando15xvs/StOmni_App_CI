-- Fase 3.7 / F2.4: los RPC internos llamados por Edge usan service_role y por
-- tanto no dependen de RLS. El tenant validado por auth_guard viaja en un header
-- interno y se exige dentro de PostgreSQL. authenticated no ejecuta estas RPC.
BEGIN;

CREATE OR REPLACE FUNCTION private.service_request_organization_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_raw text := current_setting('request.headers', true);
  v_headers jsonb;
  v_value text;
BEGIN
  IF NULLIF(v_raw,'') IS NULL THEN RETURN NULL; END IF;
  BEGIN
    v_headers:=v_raw::jsonb;
    v_value:=NULLIF(btrim(v_headers->>'x-stomni-organization-id'),'');
    IF v_value IS NULL THEN RETURN NULL; END IF;
    RETURN v_value::uuid;
  EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value THEN
    RETURN NULL;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION private.require_service_organization_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_org uuid := private.service_request_organization_id();
BEGIN
  IF v_org IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.organizations WHERE id=v_org AND status='active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Verified service organization context required';
  END IF;
  RETURN v_org;
END;
$$;

REVOKE ALL ON FUNCTION private.service_request_organization_id() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.require_service_organization_id() FROM PUBLIC,anon,authenticated;

-- -----------------------------------------------------------------------------
-- Claims internos: actor, documento, relaciones y filas de intento mismo tenant.
-- -----------------------------------------------------------------------------
DO $patch_fact_claim$
DECLARE v_sig regprocedure := 'public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)'::regprocedure; v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'WHERE e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_service_organization_id()\n      AND e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 fact claim patch mismatch: actor'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'JOIN public.ventas v ON v.id = ce.venta_id\n  WHERE ce.id = p_comprobante_id';
  v_new:=E'JOIN public.ventas v ON v.organization_id=ce.organization_id AND v.id = ce.venta_id\n  WHERE ce.organization_id = private.require_service_organization_id()\n    AND ce.id = p_comprobante_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 fact claim patch mismatch: target'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'WHERE id = p_comprobante_id;';
  v_new:=E'WHERE organization_id = private.require_service_organization_id()\n    AND id = p_comprobante_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 fact claim patch mismatch: document update'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'UPDATE public.ventas SET estado_facturacion = ''procesando''\n  WHERE id = v_comp.venta_id;';
  v_new:=E'UPDATE public.ventas SET estado_facturacion = ''procesando''\n  WHERE organization_id = private.require_service_organization_id()\n    AND id = v_comp.venta_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 fact claim patch mismatch: sale update'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'INSERT INTO public.facturacion_intentos(\n    comprobante_id, numero_intento, resultado, accion,\n    usuario_id, lock_token, fecha_inicio\n  ) VALUES (\n    p_comprobante_id, v_numero_intento, ''procesando'', v_accion,\n    p_usuario_id, v_token, now()';
  v_new:=E'INSERT INTO public.facturacion_intentos(\n    organization_id, comprobante_id, numero_intento, resultado, accion,\n    usuario_id, lock_token, fecha_inicio\n  ) VALUES (\n    private.require_service_organization_id(), p_comprobante_id, v_numero_intento, ''procesando'', v_accion,\n    p_usuario_id, v_token, now()';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 fact claim patch mismatch: attempt insert'; END IF; v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_fact_claim$;

DO $patch_note_claim$
DECLARE v_sig regprocedure := 'public.nota_credito_claim(uuid,uuid,text,boolean,boolean)'::regprocedure; v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'WHERE e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_service_organization_id()\n      AND e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 note claim patch mismatch: actor'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'FROM public.notas_credito\n  WHERE id = p_nota_credito_id\n  FOR UPDATE;';
  v_new:=E'FROM public.notas_credito\n  WHERE organization_id = private.require_service_organization_id()\n    AND id = p_nota_credito_id\n  FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 note claim patch mismatch: target'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'WHERE id = p_nota_credito_id;';
  v_new:=E'WHERE organization_id = private.require_service_organization_id()\n    AND id = p_nota_credito_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 note claim patch mismatch: updates'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'INSERT INTO public.notas_credito_intentos(\n    nota_credito_id,\n    numero_intento,';
  v_new:=E'INSERT INTO public.notas_credito_intentos(\n    organization_id,\n    nota_credito_id,\n    numero_intento,';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 note claim patch mismatch: attempt columns'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'VALUES (\n    p_nota_credito_id,\n    v_numero,';
  v_new:=E'VALUES (\n    private.require_service_organization_id(),\n    p_nota_credito_id,\n    v_numero,';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 note claim patch mismatch: attempt values'; END IF; v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_note_claim$;

DO $patch_gre_claim$
DECLARE v_sig regprocedure := 'public.gre_claim_v2(uuid,uuid,text,boolean,boolean)'::regprocedure; v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'WHERE e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_service_organization_id()\n      AND e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE claim patch mismatch: actor'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'FROM public.guias_remision\n  WHERE id = p_guia_id\n  FOR UPDATE;';
  v_new:=E'FROM public.guias_remision\n  WHERE organization_id = private.require_service_organization_id()\n    AND id = p_guia_id\n  FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE claim patch mismatch: target'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'FROM public.guias_remision_intentos\n  WHERE guia_id = p_guia_id;';
  v_new:=E'FROM public.guias_remision_intentos\n  WHERE organization_id = private.require_service_organization_id()\n    AND guia_id = p_guia_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE claim patch mismatch: attempts'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'INSERT INTO public.guias_remision_intentos(\n    guia_id, numero_intento, accion, resultado, usuario_id, lock_token\n  ) VALUES (\n    p_guia_id, v_numero, v_accion, ''procesando'', p_usuario_id, v_bloqueo';
  v_new:=E'INSERT INTO public.guias_remision_intentos(\n    organization_id, guia_id, numero_intento, accion, resultado, usuario_id, lock_token\n  ) VALUES (\n    private.require_service_organization_id(), p_guia_id, v_numero, v_accion, ''procesando'', p_usuario_id, v_bloqueo';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE claim patch mismatch: attempt insert'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'WHERE id = p_guia_id;';
  v_new:=E'WHERE organization_id = private.require_service_organization_id()\n    AND id = p_guia_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 GRE claim patch mismatch: update'; END IF; v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_gre_claim$;

DO $patch_process_claim$
DECLARE v_sig regprocedure := 'public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)'::regprocedure; v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;
  v_old:=E'WHERE e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true\n      AND e.rol = ''admin''';
  v_new:=E'WHERE e.organization_id = private.require_service_organization_id()\n      AND e.auth_id = p_usuario_id\n      AND COALESCE(e.activo, false) = true\n      AND e.rol = ''admin''';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 process claim patch mismatch: actor'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'FROM public.procesos_tributarios\n  WHERE id = p_proceso_id\n  FOR UPDATE;';
  v_new:=E'FROM public.procesos_tributarios\n  WHERE organization_id = private.require_service_organization_id()\n    AND id = p_proceso_id\n  FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 process claim patch mismatch: target'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'WHERE id = p_proceso_id;';
  v_new:=E'WHERE organization_id = private.require_service_organization_id()\n    AND id = p_proceso_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 process claim patch mismatch: updates'; END IF; v_def:=replace(v_def,v_old,v_new);
  v_old:=E'INSERT INTO public.procesos_tributarios_intentos(\n    proceso_id, numero_intento, accion, resultado,\n    usuario_id, lock_token, fecha_inicio\n  ) VALUES (\n    p_proceso_id, v_numero, v_accion, ''procesando'',\n    p_usuario_id, v_token, now()';
  v_new:=E'INSERT INTO public.procesos_tributarios_intentos(\n    organization_id, proceso_id, numero_intento, accion, resultado,\n    usuario_id, lock_token, fecha_inicio\n  ) VALUES (\n    private.require_service_organization_id(), p_proceso_id, v_numero, v_accion, ''procesando'',\n    p_usuario_id, v_token, now()';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 process claim patch mismatch: attempt insert'; END IF; v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$patch_process_claim$;

-- Finalizadores: el lock token no basta para elegir tenant; la fila objetivo debe
-- coincidir además con el header interno verificado.
DO $patch_finishers$
DECLARE v_sig regprocedure; v_def text; v_old text; v_new text; v_table text; v_param text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.facturacion_finalizar_comprobante(uuid,uuid,text,jsonb)'::regprocedure,
    'public.nota_credito_finalizar(uuid,uuid,text,jsonb)'::regprocedure,
    'public.gre_finalizar(uuid,uuid,text,jsonb)'::regprocedure,
    'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)'::regprocedure
  ] LOOP
    SELECT pg_get_functiondef(v_sig) INTO v_def;
    IF v_sig::text LIKE 'facturacion_finalizar_comprobante%' THEN v_table:='comprobantes_electronicos'; v_param:='p_comprobante_id';
    ELSIF v_sig::text LIKE 'nota_credito_finalizar%' THEN v_table:='notas_credito'; v_param:='p_nota_credito_id';
    ELSIF v_sig::text LIKE 'gre_finalizar%' THEN v_table:='guias_remision'; v_param:='p_guia_id';
    ELSE v_table:='procesos_tributarios'; v_param:='p_proceso_id'; END IF;
    v_old:=format(E'FROM public.%s\n  WHERE id = %s\n  FOR UPDATE;',v_table,v_param);
    IF strpos(v_def,v_old)=0 THEN
      -- GRE tiene SELECT * ... FROM y WHERE en una sola línea.
      v_old:=format(E'FROM public.%s\n  WHERE id = %s FOR UPDATE;',v_table,v_param);
    END IF;
    v_new:=format(E'FROM public.%s\n  WHERE organization_id = private.require_service_organization_id()\n    AND id = %s\n  FOR UPDATE;',v_table,v_param);
    IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.7 finisher patch mismatch: %',v_sig; END IF;
    v_def:=replace(v_def,v_old,v_new);
    EXECUTE v_def;
  END LOOP;
END;
$patch_finishers$;

-- -----------------------------------------------------------------------------
-- Preparación manual de resúmenes/bajas: completamente tenant-aware.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tributario_preparar_procesos(
  p_tipo_proceso text DEFAULT NULL,
  p_usuario_id uuid DEFAULT NULL,
  p_sistema boolean DEFAULT false,
  p_limite_documentos integer DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_service_organization_id();
  v_tipo_filtro text := NULLIF(lower(trim(COALESCE(p_tipo_proceso,''))),'');
  v_grupo record;
  v_proceso_id uuid;
  v_correlativo integer;
  v_identificador text;
  v_prefijo text;
  v_ids jsonb := '[]'::jsonb;
  v_count integer;
BEGIN
  IF v_tipo_filtro IS NOT NULL AND v_tipo_filtro NOT IN ('resumen_boletas','comunicacion_baja') THEN
    RAISE EXCEPTION 'Tipo de proceso inválido';
  END IF;
  IF COALESCE(p_sistema,false) THEN
    RAISE EXCEPTION 'El procesamiento tributario automático está desactivado';
  END IF;
  IF p_usuario_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.app_users au
    JOIN public.organizations o ON o.id=au.organization_id
    WHERE au.user_id=p_usuario_id AND au.organization_id=v_org
      AND au.status='active' AND au.base_role='admin' AND o.status='active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.organization_id=v_org AND COALESCE(e.activo,false)=true
      AND (e.app_user_id=p_usuario_id OR e.auth_id=p_usuario_id)
  ) THEN
    RAISE EXCEPTION 'Usuario no autorizado para preparar procesos tributarios';
  END IF;

  FOR v_grupo IN
    SELECT s.tipo_proceso,s.fecha_documento
    FROM public.solicitudes_baja_tributaria s
    WHERE s.organization_id=v_org AND s.estado='pendiente' AND s.proceso_id IS NULL
      AND (v_tipo_filtro IS NULL OR s.tipo_proceso=v_tipo_filtro)
    GROUP BY s.tipo_proceso,s.fecha_documento
    ORDER BY s.fecha_documento,s.tipo_proceso
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_org::text||':'||v_grupo.tipo_proceso||':'||v_grupo.fecha_documento::text,0));

    INSERT INTO public.correlativos_procesos_tributarios(
      organization_id,tipo_proceso,fecha_referencia,ultimo_correlativo
    ) VALUES (v_org,v_grupo.tipo_proceso,v_grupo.fecha_documento,1)
    ON CONFLICT (organization_id,tipo_proceso,fecha_referencia)
    DO UPDATE SET ultimo_correlativo=public.correlativos_procesos_tributarios.ultimo_correlativo+1,updated_at=now()
    RETURNING ultimo_correlativo INTO v_correlativo;

    v_prefijo:=CASE WHEN v_grupo.tipo_proceso='resumen_boletas' THEN 'RC' ELSE 'RA' END;
    v_identificador:=v_prefijo||'-'||to_char(v_grupo.fecha_documento,'YYYYMMDD')||'-'||lpad(v_correlativo::text,3,'0');

    INSERT INTO public.procesos_tributarios(
      organization_id,request_id,tipo_proceso,fecha_referencia,fecha_comunicacion,
      correlativo,identificador,creado_por
    ) VALUES (
      v_org,gen_random_uuid(),v_grupo.tipo_proceso,v_grupo.fecha_documento,
      (now() AT TIME ZONE 'America/Lima')::date,v_correlativo,v_identificador,p_usuario_id
    ) RETURNING id INTO v_proceso_id;

    WITH seleccion AS (
      SELECT s.id FROM public.solicitudes_baja_tributaria s
      WHERE s.organization_id=v_org AND s.estado='pendiente' AND s.proceso_id IS NULL
        AND s.tipo_proceso=v_grupo.tipo_proceso AND s.fecha_documento=v_grupo.fecha_documento
      ORDER BY s.created_at,s.id
      LIMIT GREATEST(1,LEAST(COALESCE(p_limite_documentos,500),500))
      FOR UPDATE SKIP LOCKED
    ), insertados AS (
      INSERT INTO public.procesos_tributarios_detalles(
        organization_id,proceso_id,solicitud_id,tipo_origen,
        comprobante_id,nota_credito_id,venta_id,tipo_doc,serie,correlativo,serie_numero,
        estado_resumen,motivo,moneda,cliente_tipo,cliente_numero,base_imponible,igv,total
      )
      SELECT v_org,v_proceso_id,s.id,s.tipo_origen,s.comprobante_id,s.nota_credito_id,s.venta_id,
        s.tipo_doc,s.serie,s.correlativo,s.serie||'-'||s.correlativo,'3',s.motivo,s.moneda,
        COALESCE(NULLIF(s.cliente_tipo,''),'0'),COALESCE(NULLIF(s.cliente_numero,''),'0'),
        s.base_imponible,s.igv,s.total
      FROM public.solicitudes_baja_tributaria s JOIN seleccion x ON x.id=s.id
      WHERE s.organization_id=v_org
      RETURNING solicitud_id
    )
    UPDATE public.solicitudes_baja_tributaria s
    SET estado='agrupada',proceso_id=v_proceso_id
    FROM insertados i
    WHERE s.organization_id=v_org AND s.id=i.solicitud_id;

    GET DIAGNOSTICS v_count=ROW_COUNT;
    IF v_count=0 THEN
      DELETE FROM public.procesos_tributarios WHERE organization_id=v_org AND id=v_proceso_id;
    ELSE
      UPDATE public.comprobantes_electronicos ce SET estado_baja_tributaria='agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.organization_id=v_org AND s.proceso_id=v_proceso_id
        AND ce.organization_id=v_org AND s.comprobante_id=ce.id;
      UPDATE public.notas_credito nc SET estado_baja_tributaria='agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.organization_id=v_org AND s.proceso_id=v_proceso_id
        AND nc.organization_id=v_org AND s.nota_credito_id=nc.id;
      v_ids:=v_ids||jsonb_build_array(v_proceso_id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success',true,'procesos_creados',jsonb_array_length(v_ids),'proceso_ids',v_ids);
END;
$$;

CREATE OR REPLACE FUNCTION public.tributario_reintentar_stock_bajas(p_limite integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_service_organization_id();
  v_nota record;
  v_result jsonb;
  v_total integer:=0;
BEGIN
  FOR v_nota IN
    SELECT id FROM public.notas_credito
    WHERE organization_id=v_org AND estado_baja_tributaria='aceptada' AND baja_stock_revertido=false
    ORDER BY baja_stock_ultimo_intento_at NULLS FIRST,created_at
    LIMIT GREATEST(1,LEAST(COALESCE(p_limite,20),100))
  LOOP
    v_result:=public._revertir_stock_nota_credito_por_baja(v_nota.id);
    v_total:=v_total+1;
  END LOOP;
  RETURN jsonb_build_object('success',true,'procesadas',v_total);
END;
$$;

-- La superficie sigue siendo sólo service_role.
REVOKE ALL ON FUNCTION public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.facturacion_finalizar_comprobante(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nota_credito_claim(uuid,uuid,text,boolean,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nota_credito_finalizar(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.gre_claim_v2(uuid,uuid,text,boolean,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.gre_finalizar(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.tributario_finalizar_proceso(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.tributario_preparar_procesos(text,uuid,boolean,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.tributario_reintentar_stock_bajas(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.facturacion_finalizar_comprobante(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.nota_credito_claim(uuid,uuid,text,boolean,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.nota_credito_finalizar(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.gre_claim_v2(uuid,uuid,text,boolean,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.gre_finalizar(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.tributario_finalizar_proceso(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.tributario_preparar_procesos(text,uuid,boolean,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.tributario_reintentar_stock_bajas(integer) TO service_role;

COMMIT;
