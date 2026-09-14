-- F7.4: capacidades sin business_capabilities (analytics/assistant) se guardan en sus RPC autoritativos.
BEGIN;

DO $patch$
DECLARE
  v_oid regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  -- Estas RPC se crean desde migraciones locales y PostgreSQL conserva el cuerpo
  -- con los saltos de línea del archivo fuente. En Windows pueden ser CRLF.
  -- Normalizamos únicamente CRLF -> LF antes de validar/recrear cada función;
  -- las comprobaciones siguen exigiendo exactamente una coincidencia del contrato.

  -- Dashboard configurable.
  v_oid:='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_oid),E'\r\n',E'\n');
  v_old:=E'BEGIN\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'Unexpected dashboard BEGIN contract';
  END IF;
  v_new:=E'BEGIN\n  PERFORM private.require_subscription_feature_for_org(v_org,''feature.analytics'');\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  EXECUTE replace(v_def,v_old,v_new);

  -- Listado de definiciones de métricas.
  v_oid:='public.list_business_metrics_v1()'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_oid),E'\r\n',E'\n');
  v_old:=E'BEGIN\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'Unexpected list_business_metrics_v1 definition';
  END IF;
  v_new:=E'BEGIN\n  PERFORM private.require_subscription_feature_for_org(v_org,''feature.analytics'');\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  EXECUTE replace(v_def,v_old,v_new);

  -- Configuración de métricas.
  v_oid:='public.save_business_metrics_v1(jsonb)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_oid),E'\r\n',E'\n');
  v_old:=E'BEGIN\n  IF NOT public.app_tiene_permiso(''business.configure'') THEN';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'Unexpected save_business_metrics_v1 definition';
  END IF;
  v_new:=E'BEGIN\n  PERFORM private.require_subscription_feature_for_org(v_org,''feature.analytics'');\n  IF NOT public.app_tiene_permiso(''business.configure'') THEN';
  EXECUTE replace(v_def,v_old,v_new);

  -- Uso del asistente.
  v_oid:='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_oid),E'\r\n',E'\n');
  v_old:=E'BEGIN\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'Unexpected assistant context definition';
  END IF;
  v_new:=E'BEGIN\n  PERFORM private.require_subscription_feature_for_org(v_org,''feature.business_assistant'');\n  IF NOT public.app_tiene_permiso(''reports.view_profit'') THEN';
  EXECUTE replace(v_def,v_old,v_new);

  -- Un admin tampoco puede habilitar el asistente si su plan no lo permite.
  v_oid:='public.update_business_assistant_settings_v1(bigint,boolean,integer,integer)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_oid),E'\r\n',E'\n');
  v_old:=E'BEGIN\n  IF NOT private.has_permission(''tenant.admin'') THEN';
  IF (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'Unexpected assistant settings definition';
  END IF;
  v_new:=E'BEGIN\n  IF p_enabled THEN PERFORM private.require_subscription_feature_for_org(v_org,''feature.business_assistant''); END IF;\n  IF NOT private.has_permission(''tenant.admin'') THEN';
  EXECUTE replace(v_def,v_old,v_new);
END;
$patch$;

COMMIT;
