-- =============================================================================
-- ENDURECIMIENTO TRIBUTARIO PARA PRODUCCIÓN
-- Proyecto de una sola empresa / un solo RUC
-- Roles técnicos: admin, operador
-- Procesamiento tributario: manual en la primera salida
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. PRECONDICIONES
-- -----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'empleados',
    'configuracion_negocio',
    'clientes',
    'ventas',
    'detalle_ventas',
    'pagos_venta',
    'productos',
    'almacenes',
    'inventario_almacen',
    'inventario_movimientos',
    'cotizaciones',
    'proveedores',
    'ventas_requests_anulados',
    'series_comprobantes',
    'comprobantes_electronicos',
    'facturacion_intentos',
    'constancias_descuento',
    'notas_credito',
    'notas_credito_detalles',
    'notas_credito_intentos',
    'guias_remision',
    'guias_remision_detalles',
    'guias_remision_intentos',
    'gre_conductores',
    'gre_vehiculos',
    'gre_transportistas',
    'gre_transportistas_agencias',
    'solicitudes_baja_tributaria',
    'procesos_tributarios',
    'procesos_tributarios_detalles',
    'procesos_tributarios_intentos',
    'correlativos_procesos_tributarios'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      v_missing := array_append(v_missing, v_name);
    END IF;
  END LOOP;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'Faltan tablas necesarias: %', array_to_string(v_missing, ', ');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.empleados
    WHERE rol IS NULL
       OR lower(trim(rol)) NOT IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION
      'Existen empleados con roles distintos de admin/operador. Corrígelos antes de continuar.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados
    WHERE activo IS TRUE AND rol = 'admin' AND auth_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Debe existir al menos un administrador activo con auth_id';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.configuracion_negocio WHERE id = 1) THEN
    RAISE EXCEPTION 'Falta configuracion_negocio con id=1';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos
    WHERE estado NOT IN ('pendiente','pendiente_envio','procesando','ticket_pendiente','pendiente_reintento','resultado_incierto','aceptado','rechazado')
  ) THEN RAISE EXCEPTION 'Hay estados desconocidos en comprobantes_electronicos'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.guias_remision
    WHERE estado NOT IN ('borrador','pendiente_envio','procesando','ticket_pendiente','pendiente_reintento','resultado_incierto','xml_validado_prueba','aceptado','rechazado')
  ) THEN RAISE EXCEPTION 'Hay estados desconocidos en guias_remision'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.procesos_tributarios
    WHERE estado NOT IN ('pendiente_envio','procesando','ticket_pendiente','pendiente_reintento','resultado_incierto','aceptado','rechazado')
  ) THEN RAISE EXCEPTION 'Hay estados desconocidos en procesos_tributarios'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.solicitudes_baja_tributaria
    WHERE estado NOT IN ('pendiente','agrupada','ticket_pendiente','pendiente_reintento','resultado_incierto','aceptada','rechazada','cancelada')
  ) THEN RAISE EXCEPTION 'Hay estados desconocidos en solicitudes_baja_tributaria'; END IF;
END;
$precheck$;

-- -----------------------------------------------------------------------------
-- 1. ELIMINAR AUTOMATIZACIONES TRIBUTARIAS (los cron de Sheets no se tocan)
-- -----------------------------------------------------------------------------
DO $cron$
DECLARE
  v_job record;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid
    FROM cron.job
    WHERE jobname IN (
      'facturacion_resumen_diario_22_lima',
      'facturacion_reintentos_tributarios'
    )
       OR lower(COALESCE(jobname, '')) LIKE 'facturacion%'
       OR lower(COALESCE(jobname, '')) LIKE '%tributari%'
       OR lower(COALESCE(jobname, '')) LIKE '%resumen%boleta%'
       OR lower(COALESCE(command, '')) ~ (
         'ejecutar-resumen-diario|procesar-bajas-tributarias|'
         'reintentar-comprobantes-pendientes|reintentar-notas-credito-pendientes|'
         'reintentar-guias-pendientes|reintentar-procesos-tributarios-pendientes'
       )
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;
END;
$cron$;

-- -----------------------------------------------------------------------------
-- 2. ROLES CANÓNICOS Y HELPERS RLS
-- -----------------------------------------------------------------------------
ALTER TABLE public.empleados
  ALTER COLUMN rol SET DEFAULT 'operador',
  ALTER COLUMN rol SET NOT NULL;

ALTER TABLE public.empleados
  DROP CONSTRAINT IF EXISTS empleados_rol_check;
ALTER TABLE public.empleados
  ADD CONSTRAINT empleados_rol_check
  CHECK (rol IN ('admin', 'operador'));

CREATE OR REPLACE FUNCTION public.app_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$function$;

CREATE OR REPLACE FUNCTION public.app_es_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  );
$function$;

CREATE OR REPLACE FUNCTION public._gre_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT e.rol
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND e.rol IN ('admin', 'operador')
  LIMIT 1;
$function$;

-- Política antigua con alias de roles.
DROP POLICY IF EXISTS intentos_select_supervisor ON public.facturacion_intentos;
DROP POLICY IF EXISTS intentos_select_admin ON public.facturacion_intentos;
CREATE POLICY intentos_select_admin
ON public.facturacion_intentos
FOR SELECT TO authenticated
USING (public.app_es_admin());

-- -----------------------------------------------------------------------------
-- 3. ESTADOS SEGUROS Y CAMPOS DE TRAZABILIDAD
-- -----------------------------------------------------------------------------
ALTER TABLE public.comprobantes_electronicos
  DROP CONSTRAINT IF EXISTS comprobantes_electronicos_estado_check;
ALTER TABLE public.comprobantes_electronicos
  DROP CONSTRAINT IF EXISTS comprobantes_estado_check;
ALTER TABLE public.comprobantes_electronicos
  ADD CONSTRAINT comprobantes_estado_check
  CHECK (estado IN (
    'pendiente',
    'pendiente_envio',
    'procesando',
    'ticket_pendiente',
    'pendiente_reintento',
    'resultado_incierto',
    'aceptado',
    'rechazado'
  ));

ALTER TABLE public.guias_remision
  ADD COLUMN IF NOT EXISTS ambiente_emision text NOT NULL DEFAULT 'sin_definir',
  ADD COLUMN IF NOT EXISTS ultimo_intento_por uuid;

ALTER TABLE public.guias_remision
  DROP CONSTRAINT IF EXISTS guias_remision_ambiente_emision_check;
ALTER TABLE public.guias_remision
  ADD CONSTRAINT guias_remision_ambiente_emision_check
  CHECK (ambiente_emision IN ('sin_definir', 'beta', 'produccion'));

-- Conserva la separación histórica de ambientes. Una GRE creada como
-- prueba nunca podrá reutilizarse después como documento productivo.
UPDATE public.guias_remision
SET ambiente_emision = CASE
  WHEN COALESCE(es_prueba, false) THEN 'beta'
  WHEN ticket_sunat IS NOT NULL
       OR enviado_at IS NOT NULL
       OR estado IN ('aceptado', 'rechazado') THEN 'produccion'
  ELSE ambiente_emision
END
WHERE ambiente_emision = 'sin_definir';

ALTER TABLE public.guias_remision
  DROP CONSTRAINT IF EXISTS guias_remision_estado_check;
ALTER TABLE public.guias_remision
  ADD CONSTRAINT guias_remision_estado_check
  CHECK (estado IN (
    'borrador',
    'pendiente_envio',
    'procesando',
    'ticket_pendiente',
    'pendiente_reintento',
    'resultado_incierto',
    'xml_validado_prueba',
    'aceptado',
    'rechazado'
  ));

ALTER TABLE public.guias_remision_intentos
  ADD COLUMN IF NOT EXISTS usuario_id uuid,
  ADD COLUMN IF NOT EXISTS lock_token uuid;

ALTER TABLE public.procesos_tributarios
  DROP CONSTRAINT IF EXISTS procesos_tributarios_estado_check;
ALTER TABLE public.procesos_tributarios
  ADD CONSTRAINT procesos_tributarios_estado_check
  CHECK (estado IN (
    'pendiente_envio',
    'procesando',
    'ticket_pendiente',
    'pendiente_reintento',
    'resultado_incierto',
    'aceptado',
    'rechazado'
  ));

ALTER TABLE public.solicitudes_baja_tributaria
  DROP CONSTRAINT IF EXISTS solicitudes_baja_estado_check;
ALTER TABLE public.solicitudes_baja_tributaria
  ADD CONSTRAINT solicitudes_baja_estado_check
  CHECK (estado IN (
    'pendiente',
    'agrupada',
    'ticket_pendiente',
    'pendiente_reintento',
    'resultado_incierto',
    'aceptada',
    'rechazada',
    'cancelada'
  ));

ALTER TABLE public.comprobantes_electronicos
  DROP CONSTRAINT IF EXISTS comprobantes_estado_baja_tributaria_check;
ALTER TABLE public.comprobantes_electronicos
  ADD CONSTRAINT comprobantes_estado_baja_tributaria_check
  CHECK (estado_baja_tributaria IN (
    'ninguna', 'solicitada', 'agrupada', 'ticket_pendiente',
    'pendiente_reintento', 'resultado_incierto', 'aceptada', 'rechazada'
  ));

ALTER TABLE public.notas_credito
  DROP CONSTRAINT IF EXISTS notas_credito_estado_baja_tributaria_check;
ALTER TABLE public.notas_credito
  ADD CONSTRAINT notas_credito_estado_baja_tributaria_check
  CHECK (estado_baja_tributaria IN (
    'ninguna', 'solicitada', 'agrupada', 'ticket_pendiente',
    'pendiente_reintento', 'resultado_incierto', 'aceptada', 'rechazada'
  ));

-- Convierte pendientes históricos con respuesta 5xx, timeout o conexión
-- interrumpida en resultado incierto. Es la opción segura: el proveedor pudo
-- haber recibido el documento aunque la aplicación no recibiera el resultado.
UPDATE public.comprobantes_electronicos ce
SET estado = 'resultado_incierto',
    ultimo_error_tipo = COALESCE(ce.ultimo_error_tipo, 'migracion_resultado_incierto'),
    descripcion_sunat = COALESCE(
      NULLIF(trim(ce.descripcion_sunat), ''),
      'Envío histórico sin resultado definitivo. Debe consultarse o reconciliarse antes de reenviar.'
    ),
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
WHERE ce.estado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(ce.ultimo_http_status, 0) >= 500
    OR lower(COALESCE(ce.ultimo_error_tipo, '')) ~ '(timeout|conexion|conexión|incierto)'
  );

UPDATE public.ventas v
SET estado_facturacion = 'resultado_incierto'
FROM public.comprobantes_electronicos ce
WHERE ce.venta_id = v.id
  AND ce.estado = 'resultado_incierto';

UPDATE public.facturacion_intentos fi
SET resultado = 'resultado_incierto'
WHERE fi.resultado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(fi.codigo_http, 0) >= 500
    OR lower(COALESCE(fi.mensaje_error, '')) ~ '(timeout|conexi[oó]n|servidor interno)'
  );

UPDATE public.notas_credito nc
SET estado = 'resultado_incierto',
    ultimo_error_tipo = COALESCE(nc.ultimo_error_tipo, 'migracion_resultado_incierto'),
    descripcion_sunat = COALESCE(
      NULLIF(trim(nc.descripcion_sunat), ''),
      'Envío histórico sin resultado definitivo. Debe reconciliarse antes de reenviar.'
    ),
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
WHERE nc.estado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(nc.ultimo_http_status, 0) >= 500
    OR lower(COALESCE(nc.ultimo_error_tipo, '')) ~ '(timeout|conexion|conexión|incierto)'
  );

UPDATE public.notas_credito_intentos ni
SET resultado = 'resultado_incierto'
WHERE ni.resultado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(ni.codigo_http, 0) >= 500
    OR lower(COALESCE(ni.mensaje_error, '')) ~ '(timeout|conexi[oó]n|servidor interno)'
  );

UPDATE public.guias_remision g
SET estado = 'resultado_incierto',
    ultimo_error_tipo = COALESCE(g.ultimo_error_tipo, 'migracion_resultado_incierto'),
    descripcion_sunat = COALESCE(
      NULLIF(trim(g.descripcion_sunat), ''),
      'Envío histórico sin resultado definitivo. Debe reconciliarse antes de reenviar.'
    ),
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
WHERE g.estado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(g.ultimo_http_status, 0) >= 500
    OR lower(COALESCE(g.ultimo_error_tipo, '')) ~ '(timeout|conexion|conexión|incierto)'
  );

UPDATE public.guias_remision_intentos gi
SET resultado = 'resultado_incierto'
WHERE gi.resultado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(gi.codigo_http, 0) >= 500
    OR lower(COALESCE(gi.mensaje_error, '')) ~ '(timeout|conexi[oó]n|servidor interno)'
  );

UPDATE public.procesos_tributarios pt
SET estado = 'resultado_incierto',
    ultimo_error_tipo = COALESCE(pt.ultimo_error_tipo, 'migracion_resultado_incierto'),
    descripcion_sunat = COALESCE(
      NULLIF(trim(pt.descripcion_sunat), ''),
      'Envío histórico sin resultado definitivo. Debe reconciliarse antes de reenviar.'
    ),
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
WHERE pt.estado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(pt.ultimo_http_status, 0) >= 500
    OR lower(COALESCE(pt.ultimo_error_tipo, '')) ~ '(timeout|conexion|conexión|incierto)'
  );

UPDATE public.procesos_tributarios_intentos pi
SET resultado = 'resultado_incierto'
WHERE pi.resultado IN ('pendiente_reintento', 'procesando')
  AND (
    COALESCE(pi.codigo_http, 0) >= 500
    OR lower(COALESCE(pi.mensaje_error, '')) ~ '(timeout|conexi[oó]n|servidor interno)'
  );

UPDATE public.solicitudes_baja_tributaria s
SET estado = 'resultado_incierto'
FROM public.procesos_tributarios pt
WHERE s.proceso_id = pt.id
  AND pt.estado = 'resultado_incierto';

UPDATE public.comprobantes_electronicos ce
SET estado_baja_tributaria = 'resultado_incierto'
FROM public.solicitudes_baja_tributaria s,
     public.procesos_tributarios pt
WHERE s.comprobante_id = ce.id
  AND s.proceso_id = pt.id
  AND pt.estado = 'resultado_incierto';

UPDATE public.notas_credito nc
SET estado_baja_tributaria = 'resultado_incierto'
FROM public.solicitudes_baja_tributaria s,
     public.procesos_tributarios pt
WHERE s.nota_credito_id = nc.id
  AND s.proceso_id = pt.id
  AND pt.estado = 'resultado_incierto';

-- Auditoría explícita de cada decisión sobre resultados inciertos.
CREATE TABLE IF NOT EXISTS public.documentos_tributarios_reconciliaciones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_documento text NOT NULL CHECK (
    tipo_documento IN ('comprobante', 'nota_credito', 'guia', 'proceso')
  ),
  documento_id uuid NOT NULL,
  decision text NOT NULL CHECK (
    decision IN ('habilitar_reintento', 'mantener_incierto')
  ),
  estado_anterior text NOT NULL,
  estado_nuevo text NOT NULL,
  motivo text NOT NULL CHECK (char_length(trim(motivo)) BETWEEN 10 AND 500),
  referencia_externa text,
  realizado_por uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reconciliaciones_documento
  ON public.documentos_tributarios_reconciliaciones
  (tipo_documento, documento_id, created_at DESC);

ALTER TABLE public.documentos_tributarios_reconciliaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documentos_tributarios_reconciliaciones FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliaciones_admin_select
  ON public.documentos_tributarios_reconciliaciones;
CREATE POLICY reconciliaciones_admin_select
  ON public.documentos_tributarios_reconciliaciones
  FOR SELECT TO authenticated
  USING (public.app_es_admin());

CREATE INDEX IF NOT EXISTS idx_comprobantes_resultado_incierto
  ON public.comprobantes_electronicos (ultimo_intento_at, created_at, id)
  WHERE estado = 'resultado_incierto';
CREATE INDEX IF NOT EXISTS idx_guias_resultado_incierto
  ON public.guias_remision (ultimo_intento_at, created_at, id)
  WHERE estado = 'resultado_incierto';
CREATE INDEX IF NOT EXISTS idx_notas_resultado_incierto
  ON public.notas_credito (ultimo_intento_at, created_at, id)
  WHERE estado = 'resultado_incierto';
CREATE INDEX IF NOT EXISTS idx_procesos_resultado_incierto
  ON public.procesos_tributarios (ultimo_intento_at, created_at, id)
  WHERE estado = 'resultado_incierto';

-- -----------------------------------------------------------------------------
-- 4. CONFIGURACIÓN DE EMPRESA: SOLO DATOS GENERALES, NO REGLAS TRIBUTARIAS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_configuracion_negocio_v1(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_row public.configuracion_negocio%ROWTYPE;
  v_ruc text;
  v_ubigeo text;
  v_razon_social text;
  v_direccion text;
  v_departamento text;
  v_provincia text;
  v_distrito text;
  v_cod_local text;
  v_keys_permitidas constant text[] := ARRAY[
    'razon_social', 'nombre_comercial', 'ruc', 'direccion', 'ubigeo',
    'departamento', 'provincia', 'distrito', 'cod_local', 'telefono', 'logo_url'
  ];
  v_key text;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede modificar la empresa';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'Los datos de configuración son inválidos';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_datos)
  LOOP
    IF NOT (v_key = ANY (v_keys_permitidas)) THEN
      RAISE EXCEPTION 'Campo no permitido en esta pantalla: %', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_row
  FROM public.configuracion_negocio
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe configuracion_negocio con id=1. Créala antes de usar esta RPC.';
  END IF;

  v_ruc := trim(COALESCE(p_datos->>'ruc', v_row.ruc, ''));
  v_ubigeo := trim(COALESCE(p_datos->>'ubigeo', v_row.ubigeo, ''));
  v_razon_social := trim(COALESCE(p_datos->>'razon_social', v_row.razon_social, ''));
  v_direccion := trim(COALESCE(p_datos->>'direccion', v_row.direccion, ''));
  v_departamento := upper(trim(COALESCE(p_datos->>'departamento', v_row.departamento, '')));
  v_provincia := upper(trim(COALESCE(p_datos->>'provincia', v_row.provincia, '')));
  v_distrito := upper(trim(COALESCE(p_datos->>'distrito', v_row.distrito, '')));
  v_cod_local := trim(COALESCE(p_datos->>'cod_local', v_row.cod_local, '0000'));

  IF v_ruc !~ '^[0-9]{11}$' THEN
    RAISE EXCEPTION 'El RUC debe contener exactamente 11 dígitos';
  END IF;
  IF v_ubigeo !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'El ubigeo debe contener exactamente 6 dígitos';
  END IF;
  IF v_razon_social = '' OR v_direccion = '' OR v_departamento = ''
     OR v_provincia = '' OR v_distrito = '' THEN
    RAISE EXCEPTION 'Razón social y domicilio fiscal completo son obligatorios';
  END IF;
  IF v_cod_local !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El código de local debe contener exactamente 4 dígitos';
  END IF;

  UPDATE public.configuracion_negocio c
  SET
    razon_social = CASE WHEN p_datos ? 'razon_social' THEN v_razon_social ELSE c.razon_social END,
    nombre_comercial = CASE WHEN p_datos ? 'nombre_comercial' THEN NULLIF(trim(p_datos->>'nombre_comercial'), '') ELSE c.nombre_comercial END,
    ruc = CASE WHEN p_datos ? 'ruc' THEN v_ruc ELSE c.ruc END,
    direccion = CASE WHEN p_datos ? 'direccion' THEN v_direccion ELSE c.direccion END,
    ubigeo = CASE WHEN p_datos ? 'ubigeo' THEN v_ubigeo ELSE c.ubigeo END,
    departamento = CASE WHEN p_datos ? 'departamento' THEN v_departamento ELSE c.departamento END,
    provincia = CASE WHEN p_datos ? 'provincia' THEN v_provincia ELSE c.provincia END,
    distrito = CASE WHEN p_datos ? 'distrito' THEN v_distrito ELSE c.distrito END,
    cod_local = CASE WHEN p_datos ? 'cod_local' THEN v_cod_local ELSE c.cod_local END,
    telefono = CASE WHEN p_datos ? 'telefono' THEN NULLIF(trim(p_datos->>'telefono'), '') ELSE c.telefono END,
    logo_url = CASE WHEN p_datos ? 'logo_url' THEN NULLIF(trim(p_datos->>'logo_url'), '') ELSE c.logo_url END
  WHERE c.id = 1
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5. FACTURAS Y BOLETAS: CLAIM/FINALIZACIÓN SEGUROS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.facturacion_claim_comprobante(
  p_comprobante_id uuid,
  p_usuario_id uuid,
  p_accion text DEFAULT 'emitir',
  p_forzar boolean DEFAULT false,
  p_sistema boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_comp record;
  v_token uuid := gen_random_uuid();
  v_numero_intento integer;
  v_intento_id uuid;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_es_admin boolean := false;
BEGIN
  IF p_comprobante_id IS NULL THEN
    RAISE EXCEPTION 'comprobante_id es obligatorio';
  END IF;
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción de facturación inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    SELECT e.rol = 'admin'
    INTO v_es_admin
    FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rol no autorizado para procesar comprobantes';
    END IF;
  END IF;

  IF COALESCE(p_forzar, false) AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar un reintento';
  END IF;

  SELECT ce.*, v.saldo AS venta_saldo, v.estado AS venta_estado,
         v.tipo_comprobante_solicitado
  INTO v_comp
  FROM public.comprobantes_electronicos ce
  JOIN public.ventas v ON v.id = ce.venta_id
  WHERE ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN RAISE EXCEPTION 'Comprobante no encontrado'; END IF;

  IF lower(COALESCE(v_comp.tipo_documento_sunat, '')) NOT IN ('factura', 'boleta') THEN
    RAISE EXCEPTION 'El registro no corresponde a factura o boleta';
  END IF;

  IF COALESCE(v_comp.venta_saldo, 0) > 0.01
     OR lower(COALESCE(v_comp.venta_estado, '')) <> 'pagado' THEN
    RAISE EXCEPTION 'Las facturas y boletas electrónicas solo pueden emitirse al contado';
  END IF;

  IF lower(COALESCE(v_comp.tipo_comprobante_solicitado, ''))
     <> lower(COALESCE(v_comp.tipo_documento_sunat, '')) THEN
    RAISE EXCEPTION 'El tipo solicitado por la venta no coincide con el comprobante';
  END IF;

  IF v_comp.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'comprobante_id', v_comp.id, 'mensaje', 'El comprobante ya fue aceptado');
  END IF;

  IF v_comp.estado = 'procesando'
     AND v_comp.bloqueo_expira_at IS NOT NULL
     AND v_comp.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'comprobante_id', v_comp.id, 'mensaje', 'El comprobante ya está siendo procesado');
  END IF;

  -- Un worker caído después de iniciar el envío puede haber llegado a SUNAT.
  IF v_comp.estado = 'procesando'
     AND (v_comp.bloqueo_expira_at IS NULL OR v_comp.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.comprobantes_electronicos
    SET estado = 'resultado_incierto',
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(
          descripcion_sunat,
          'El proceso anterior quedó interrumpido. Consulte SUNAT antes de reenviar.'
        )
    WHERE id = p_comprobante_id;
    UPDATE public.ventas SET estado_facturacion = 'resultado_incierto'
    WHERE id = v_comp.venta_id;
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. Debe consultarse antes de reenviar.');
  END IF;

  IF v_comp.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El resultado es incierto. Consulte o reconcilie el documento antes de habilitar un reintento.');
  END IF;

  IF v_comp.ticket_sunat IS NOT NULL AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'El comprobante ya tiene ticket. Debe consultarse, no reenviarse.');
  END IF;

  IF v_comp.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', COALESCE(v_comp.descripcion_sunat,
        'El comprobante fue rechazado y requiere revisión'));
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_comp.estado NOT IN (
      'pendiente', 'pendiente_envio', 'pendiente_reintento', 'procesando',
      'resultado_incierto', 'ticket_pendiente', 'rechazado'
    ) THEN
      RAISE EXCEPTION 'Estado no consultable: %', v_comp.estado;
    END IF;
  ELSIF v_comp.estado NOT IN (
    'pendiente', 'pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_comp.estado;
  END IF;

  v_numero_intento := COALESCE(v_comp.numero_reintentos, 0) + 1;

  UPDATE public.comprobantes_electronicos
  SET estado = 'procesando', numero_reintentos = v_numero_intento,
      ultimo_intento_at = now(), procesando_at = now(),
      bloqueo_token = v_token, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_comprobante_id;

  UPDATE public.ventas SET estado_facturacion = 'procesando'
  WHERE id = v_comp.venta_id;

  INSERT INTO public.facturacion_intentos(
    comprobante_id, numero_intento, resultado, accion,
    usuario_id, lock_token, fecha_inicio
  ) VALUES (
    p_comprobante_id, v_numero_intento, 'procesando', v_accion,
    p_usuario_id, v_token, now()
  ) RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true, 'estado', 'procesando',
    'estado_anterior', v_comp.estado,
    'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id,
    'bloqueo_token', v_token, 'intento_id', v_intento_id,
    'numero_intento', v_numero_intento
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.facturacion_finalizar_comprobante(
  p_comprobante_id uuid,
  p_bloqueo_token uuid,
  p_estado text,
  p_resultado jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_comp record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'aceptado', 'rechazado', 'pendiente_reintento',
    'resultado_incierto', 'ticket_pendiente'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_comp
  FROM public.comprobantes_electronicos
  WHERE id = p_comprobante_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comprobante no encontrado'; END IF;

  IF v_comp.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado,
      'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
  END IF;

  IF v_comp.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_comp.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'comprobante_id', p_comprobante_id,
        'venta_id', v_comp.venta_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del comprobante ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.comprobantes_electronicos
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE
        WHEN v_estado IN ('aceptado', 'rechazado', 'ticket_pendiente', 'resultado_incierto')
          OR COALESCE((p_resultado->>'remoto_iniciado')::boolean, false)
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_comprobante_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.facturacion_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.ventas SET estado_facturacion = v_estado
  WHERE id = v_comp.venta_id;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 6. GRE: CLAIM CON IDENTIDAD, BETA XML Y RESULTADO INCIERTO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gre_claim_v2(
  p_guia_id uuid,
  p_usuario_id uuid,
  p_accion text DEFAULT 'emitir',
  p_forzar boolean DEFAULT false,
  p_sistema boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_bloqueo uuid := gen_random_uuid();
  v_intento_id uuid;
  v_numero integer;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_es_admin boolean := false;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción GRE inválida';
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    SELECT e.rol = 'admin' INTO v_es_admin
    FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'Rol no autorizado para procesar GRE'; END IF;
  END IF;

  IF COALESCE(p_forzar, false) AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar una GRE';
  END IF;

  SELECT * INTO v_guia
  FROM public.guias_remision
  WHERE id = p_guia_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;

  IF v_guia.estado = 'borrador' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'borrador',
      'mensaje', 'Completa y prepara la guía antes de emitir.');
  END IF;
  IF v_guia.serie IS NULL OR v_guia.correlativo IS NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', v_guia.estado,
      'mensaje', 'La guía todavía no tiene serie y correlativo.');
  END IF;
  IF v_guia.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'mensaje', 'La guía ya fue aceptada.');
  END IF;
  IF v_guia.estado = 'xml_validado_prueba' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'xml_validado_prueba',
      'mensaje', 'La guía ya fue validada como prueba. Crea una nueva para producción.');
  END IF;

  IF v_guia.estado = 'procesando'
     AND v_guia.bloqueo_expira_at IS NOT NULL
     AND v_guia.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'mensaje', 'La guía está siendo procesada.');
  END IF;

  IF v_guia.estado = 'procesando'
     AND (v_guia.bloqueo_expira_at IS NULL OR v_guia.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.guias_remision
    SET estado = 'resultado_incierto', procesando_at = NULL,
        bloqueo_token = NULL, bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(descripcion_sunat,
          'El proceso anterior quedó interrumpido. Debe reconciliarse antes de reenviar.')
    WHERE id = p_guia_id;
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. No reenvíe la GRE.');
  END IF;

  IF v_guia.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'La GRE tiene resultado incierto y requiere reconciliación administrativa.');
  END IF;

  IF v_guia.ticket_sunat IS NOT NULL AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'La GRE tiene ticket y solo debe consultarse.');
  END IF;

  IF v_guia.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', COALESCE(v_guia.descripcion_sunat,
        'Corrige los datos antes de volver a emitir.'));
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_guia.ticket_sunat IS NULL THEN
      RETURN jsonb_build_object('claimed', false, 'estado', v_guia.estado,
        'mensaje', 'La GRE no tiene ticket. Si el envío fue incierto, debe reconciliarse manualmente.');
    END IF;
  ELSIF v_guia.estado NOT IN (
    'pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado GRE no procesable: %', v_guia.estado;
  END IF;

  SELECT COALESCE(max(numero_intento), 0) + 1 INTO v_numero
  FROM public.guias_remision_intentos
  WHERE guia_id = p_guia_id;

  INSERT INTO public.guias_remision_intentos(
    guia_id, numero_intento, accion, resultado, usuario_id, lock_token
  ) VALUES (
    p_guia_id, v_numero, v_accion, 'procesando', p_usuario_id, v_bloqueo
  ) RETURNING id INTO v_intento_id;

  UPDATE public.guias_remision
  SET estado = 'procesando', procesando_at = now(),
      bloqueo_token = v_bloqueo, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_at = now(), ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_guia_id;

  RETURN jsonb_build_object(
    'claimed', true, 'guia_id', p_guia_id,
    'estado_anterior', v_guia.estado,
    'bloqueo_token', v_bloqueo, 'intento_id', v_intento_id,
    'numero_intento', v_numero, 'ticket_sunat', v_guia.ticket_sunat
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gre_finalizar(
  p_guia_id uuid,
  p_bloqueo_token uuid,
  p_estado text,
  p_resultado jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'pendiente_envio', 'ticket_pendiente', 'pendiente_reintento',
    'resultado_incierto', 'xml_validado_prueba', 'aceptado', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado final GRE inválido: %', v_estado;
  END IF;

  SELECT * INTO v_guia FROM public.guias_remision
  WHERE id = p_guia_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;

  IF v_guia.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
  END IF;

  IF v_guia.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_guia.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
    END IF;
    RAISE EXCEPTION 'El bloqueo de la guía ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.guias_remision
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ambiente_emision = COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision),
      es_prueba = COALESCE(NULLIF(p_resultado->>'es_prueba', '')::boolean, es_prueba),
      ultimo_http_status = v_codigo_http,
      ultimo_error_tipo = CASE WHEN v_estado IN ('aceptado', 'xml_validado_prueba') THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        AND COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision) = 'produccion'
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_guia_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.guias_remision_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'guia_id', p_guia_id, 'estado', v_estado);
END;
$function$;
CREATE OR REPLACE FUNCTION public.nota_credito_claim(p_nota_credito_id uuid, p_usuario_id uuid, p_accion text DEFAULT 'emitir'::text, p_forzar boolean DEFAULT false, p_sistema boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_nota record;
  v_accion text := LOWER(TRIM(COALESCE(p_accion, 'emitir')));
  v_token uuid := gen_random_uuid();
  v_numero integer;
  v_intento_id uuid;
  v_total_original numeric(14,2);
  v_total_otros numeric(14,2);
  v_det_check record;
  v_cantidad_otros integer;
  v_es_admin boolean := false;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar') THEN
    RAISE EXCEPTION 'Acción inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    IF p_usuario_id IS NULL THEN
      RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    SELECT e.rol = 'admin'
    INTO v_es_admin
    FROM public.empleados AS e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rol no autorizado para notas de crédito';
    END IF;
  END IF;

  SELECT *
  INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado = 'aceptado' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'aceptado',
      'mensaje', 'La nota de crédito ya fue aceptada'
    );
  END IF;

  IF v_nota.estado = 'procesando'
     AND v_nota.bloqueo_expira_at IS NOT NULL
     AND v_nota.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'procesando',
      'mensaje', 'La nota ya está siendo procesada'
    );
  END IF;

  IF v_nota.estado = 'procesando'
     AND (v_nota.bloqueo_expira_at IS NULL OR v_nota.bloqueo_expira_at <= now()) THEN
    UPDATE public.notas_credito
    SET estado = 'resultado_incierto',
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(
          descripcion_sunat,
          'El proceso anterior quedó interrumpido. Reconcilie la nota antes de reenviar.'
        )
    WHERE id = p_nota_credito_id;

    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. La nota debe reconciliarse.'
    );
  END IF;

  IF v_nota.estado = 'resultado_incierto' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'resultado_incierto',
      'mensaje', COALESCE(
        v_nota.descripcion_sunat,
        'El resultado remoto es incierto. Un administrador debe reconciliar la nota antes de habilitar otro intento.'
      )
    );
  END IF;

  IF v_nota.estado = 'rechazado' AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'rechazado',
      'mensaje', COALESCE(
        v_nota.descripcion_sunat,
        'La nota fue rechazada y requiere revisión'
      )
    );
  END IF;

  IF v_nota.estado = 'rechazado'
     AND COALESCE(p_forzar, false)
     AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar una nota rechazada';
  END IF;

  -- Antes de forzar una nota rechazada o incierta volvemos a validar que
  -- otras notas posteriores no hayan consumido el saldo o las cantidades.
  IF v_nota.estado = 'rechazado'
     AND COALESCE(p_forzar, false) THEN
    IF v_nota.afecta_dinero = true THEN
      SELECT
        ce.total,
        COALESCE(SUM(nc.total), 0)
      INTO v_total_original, v_total_otros
      FROM public.comprobantes_electronicos AS ce
      LEFT JOIN public.notas_credito AS nc
        ON nc.comprobante_id = ce.id
       AND nc.id <> v_nota.id
       AND nc.afecta_dinero = true
       AND nc.estado IN (
         'pendiente_envio',
         'procesando',
         'pendiente_reintento',
         'resultado_incierto',
         'aceptado'
       )
      WHERE ce.id = v_nota.comprobante_id
      GROUP BY ce.total;

      IF COALESCE(v_total_otros, 0) + COALESCE(v_nota.total, 0)
          > COALESCE(v_total_original, 0) + 0.02 THEN
        RAISE EXCEPTION
          'No se puede reintentar: otras notas consumieron el saldo tributario disponible';
      END IF;
    END IF;

    IF v_nota.afecta_stock = true THEN
      FOR v_det_check IN
        SELECT ncd.detalle_venta_id, ncd.cantidad_visual, dv.cantidad
        FROM public.notas_credito_detalles AS ncd
        JOIN public.detalle_ventas AS dv ON dv.id = ncd.detalle_venta_id
        WHERE ncd.nota_credito_id = v_nota.id
          AND ncd.detalle_venta_id IS NOT NULL
      LOOP
        SELECT COALESCE(SUM(ncd2.cantidad_visual), 0)::integer
        INTO v_cantidad_otros
        FROM public.notas_credito_detalles AS ncd2
        JOIN public.notas_credito AS nc2 ON nc2.id = ncd2.nota_credito_id
        WHERE ncd2.detalle_venta_id = v_det_check.detalle_venta_id
          AND nc2.id <> v_nota.id
          AND nc2.afecta_stock = true
          AND nc2.estado IN (
            'pendiente_envio',
            'procesando',
            'pendiente_reintento',
            'resultado_incierto',
            'aceptado'
          );

        IF COALESCE(v_cantidad_otros, 0) + v_det_check.cantidad_visual
            > v_det_check.cantidad THEN
          RAISE EXCEPTION
            'No se puede reintentar: otra nota consumió la cantidad disponible del detalle %',
            v_det_check.detalle_venta_id;
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF v_nota.estado NOT IN (
    'pendiente_envio',
    'pendiente_reintento',
    'procesando',
    'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_nota.estado;
  END IF;

  v_numero := COALESCE(v_nota.numero_reintentos, 0) + 1;

  UPDATE public.notas_credito
  SET
    estado = 'procesando',
    numero_reintentos = v_numero,
    ultimo_intento_at = now(),
    procesando_at = now(),
    bloqueo_token = v_token,
    bloqueo_expira_at = now() + interval '3 minutes',
    ultimo_intento_por = p_usuario_id,
    ultimo_error_tipo = NULL,
    ultimo_http_status = NULL
  WHERE id = p_nota_credito_id;

  INSERT INTO public.notas_credito_intentos(
    nota_credito_id,
    numero_intento,
    accion,
    resultado,
    usuario_id,
    lock_token,
    fecha_inicio
  )
  VALUES (
    p_nota_credito_id,
    v_numero,
    v_accion,
    'procesando',
    p_usuario_id,
    v_token,
    now()
  )
  RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true,
    'estado', 'procesando',
    'nota_credito_id', p_nota_credito_id,
    'bloqueo_token', v_token,
    'intento_id', v_intento_id,
    'numero_intento', v_numero
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.nota_credito_finalizar(p_nota_credito_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_nota record;
  v_estado text := LOWER(TRIM(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_stock_result jsonb;
  v_total_nc numeric(14,2);
  v_venta_total numeric(14,2);
BEGIN
  IF v_estado NOT IN ('aceptado', 'rechazado', 'pendiente_reintento', 'resultado_incierto') THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object(
      'success', true, 'estado', 'aceptado', 'idempotent', true,
      'ignored_state', v_estado, 'nota_credito_id', p_nota_credito_id
    );
  END IF;

  IF v_nota.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_nota.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object(
        'success', true, 'estado', 'aceptado', 'idempotent', true,
        'nota_credito_id', p_nota_credito_id
      );
    END IF;
    RAISE EXCEPTION 'El bloqueo de la nota ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(TRIM(p_resultado->>'mensaje_error'), '');

  UPDATE public.notas_credito
  SET
    estado = v_estado,
    payload_json = COALESCE(p_resultado->'payload_json', payload_json),
    respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
    xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
    cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
    pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
    hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
    codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
    descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
    observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
    archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
    ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
    ultimo_error_tipo = CASE
      WHEN v_estado = 'aceptado' THEN NULL
      ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo)
    END,
    ultimo_http_status = v_codigo_http,
    enviado_at = CASE
      WHEN v_estado IN ('aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now())
      ELSE enviado_at
    END,
    aceptado_at = CASE
      WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now())
      ELSE aceptado_at
    END,
    pdf_generado_at = CASE
      WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL THEN now()
      ELSE pdf_generado_at
    END,
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
  WHERE id = p_nota_credito_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.notas_credito_intentos
    SET
      resultado = v_estado,
      codigo_http = v_codigo_http,
      codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
      mensaje_error = v_mensaje,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      fecha_fin = now(),
      duracion_ms = COALESCE(
        v_duracion,
        GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (now() - fecha_inicio)) * 1000)::integer)
      )
    WHERE id = v_intento_id;
  END IF;

  IF v_estado = 'aceptado'
     AND v_nota.reponer_stock = true
     AND v_nota.stock_aplicado = false THEN
    v_stock_result := public._aplicar_stock_nota_credito(p_nota_credito_id);
  END IF;

  SELECT
    COALESCE(SUM(nc.total), 0),
    v.total
  INTO v_total_nc, v_venta_total
  FROM public.ventas AS v
  LEFT JOIN public.notas_credito AS nc
    ON nc.venta_id = v.id
   AND nc.estado = 'aceptado'
   AND nc.afecta_dinero = true
   AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
  WHERE v.id = v_nota.venta_id
  GROUP BY v.total;

  UPDATE public.ventas
  SET
    monto_notas_credito = ROUND(COALESCE(v_total_nc, 0), 2),
    estado_tributario = CASE
      WHEN COALESCE(v_total_nc, 0) >= COALESCE(v_venta_total, 0) - 0.02 THEN 'anulada'
      WHEN COALESCE(v_total_nc, 0) > 0.01 THEN 'parcialmente_ajustada'
      ELSE 'vigente'
    END
  WHERE id = v_nota.venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'estado', v_estado,
    'nota_credito_id', p_nota_credito_id,
    'venta_id', v_nota.venta_id,
    'stock_aplicado', CASE
      WHEN v_estado = 'aceptado' THEN (
        SELECT stock_aplicado FROM public.notas_credito
        WHERE id = p_nota_credito_id
      )
      ELSE false
    END,
    'stock_resultado', v_stock_result,
    'stock_error', (
      SELECT stock_error FROM public.notas_credito
      WHERE id = p_nota_credito_id
    )
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 7. RESÚMENES Y BAJAS: SOLO ADMIN, TICKET IRREVERSIBLE, ESTADO INCIERTO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tributario_claim_proceso(
  p_proceso_id uuid,
  p_usuario_id uuid,
  p_accion text DEFAULT 'emitir',
  p_forzar boolean DEFAULT false,
  p_sistema boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_proceso record;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_token uuid := gen_random_uuid();
  v_numero integer;
  v_intento_id uuid;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción tributaria inválida';
  END IF;

  -- En la primera salida todos los procesos son manuales y administrativos.
  IF COALESCE(p_sistema, false) THEN
    RAISE EXCEPTION 'El procesamiento tributario automático está desactivado';
  END IF;

  IF p_usuario_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede procesar resúmenes y bajas';
  END IF;

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'idempotent', true, 'mensaje', 'El proceso ya fue aceptado');
  END IF;

  IF v_proceso.estado = 'procesando'
     AND v_proceso.bloqueo_expira_at IS NOT NULL
     AND v_proceso.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'mensaje', 'Otro proceso continúa trabajando');
  END IF;

  IF v_proceso.estado = 'procesando'
     AND (v_proceso.bloqueo_expira_at IS NULL OR v_proceso.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.procesos_tributarios
    SET estado = 'resultado_incierto', procesando_at = NULL,
        bloqueo_token = NULL, bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(descripcion_sunat,
          'El envío anterior quedó interrumpido. Debe reconciliarse antes de reenviar.')
    WHERE id = p_proceso_id;

    UPDATE public.solicitudes_baja_tributaria
    SET estado = 'resultado_incierto'
    WHERE proceso_id = p_proceso_id;

    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. No reenvíe el proceso.');
  END IF;

  IF v_proceso.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El proceso debe reconciliarse antes de habilitar otro envío.');
  END IF;

  IF v_accion = 'consultar' AND v_proceso.ticket_sunat IS NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', v_proceso.estado,
      'mensaje', 'El proceso no tiene ticket. Debe reconciliarse manualmente.');
  END IF;

  IF v_accion IN ('emitir', 'reintentar') AND v_proceso.ticket_sunat IS NOT NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'El proceso ya tiene ticket. Debe consultarse, no reenviarse.');
  END IF;

  IF v_proceso.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', 'El proceso fue rechazado. Revise el error antes de forzar.');
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_proceso.estado NOT IN ('ticket_pendiente', 'resultado_incierto', 'rechazado', 'procesando') THEN
      RAISE EXCEPTION 'Estado no consultable: %', v_proceso.estado;
    END IF;
  ELSIF v_proceso.estado NOT IN ('pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado') THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_proceso.estado;
  END IF;

  v_numero := COALESCE(v_proceso.numero_reintentos, 0) + 1;
  UPDATE public.procesos_tributarios
  SET estado = 'procesando', numero_reintentos = v_numero,
      ultimo_intento_at = now(), procesando_at = now(),
      bloqueo_token = v_token, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_proceso_id;

  INSERT INTO public.procesos_tributarios_intentos(
    proceso_id, numero_intento, accion, resultado,
    usuario_id, lock_token, fecha_inicio
  ) VALUES (
    p_proceso_id, v_numero, v_accion, 'procesando',
    p_usuario_id, v_token, now()
  ) RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true, 'estado', 'procesando',
    'estado_anterior', v_proceso.estado,
    'proceso_id', p_proceso_id, 'bloqueo_token', v_token,
    'intento_id', v_intento_id, 'numero_intento', v_numero,
    'accion', v_accion
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.tributario_finalizar_proceso(
  p_proceso_id uuid,
  p_bloqueo_token uuid,
  p_estado text,
  p_resultado jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_proceso record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_det record;
  v_stock_result jsonb;
BEGIN
  IF v_estado NOT IN (
    'ticket_pendiente', 'aceptado', 'rechazado',
    'pendiente_reintento', 'resultado_incierto'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado, 'proceso_id', p_proceso_id);
  END IF;

  IF v_proceso.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_proceso.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'proceso_id', p_proceso_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del proceso ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.procesos_tributarios
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_proceso_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.procesos_tributarios_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.solicitudes_baja_tributaria
  SET estado = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE estado END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END
  WHERE proceso_id = p_proceso_id;

  UPDATE public.comprobantes_electronicos ce
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE ce.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(ce.baja_aceptada_at, now()) ELSE ce.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.comprobante_id = ce.id;

  UPDATE public.notas_credito nc
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE nc.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(nc.baja_aceptada_at, now()) ELSE nc.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.nota_credito_id = nc.id;

  IF v_estado = 'aceptado' THEN
    UPDATE public.ventas v
    SET estado_tributario = 'baja_tributaria'
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_proceso_id
      AND s.tipo_origen = 'comprobante'
      AND s.venta_id = v.id;

    FOR v_det IN
      SELECT DISTINCT d.nota_credito_id, d.venta_id
      FROM public.procesos_tributarios_detalles d
      WHERE d.proceso_id = p_proceso_id AND d.nota_credito_id IS NOT NULL
    LOOP
      v_stock_result := public._revertir_stock_nota_credito_por_baja(v_det.nota_credito_id);
      PERFORM public.recalcular_estado_tributario_venta(v_det.venta_id);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'proceso_id', p_proceso_id, 'stock_resultado', v_stock_result);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 8. RECONCILIACIÓN ADMINISTRATIVA (nunca permite marcar aceptado manualmente)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolver_resultado_incierto_v1(
  p_tipo_documento text,
  p_documento_id uuid,
  p_decision text,
  p_motivo text,
  p_referencia_externa text,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_tipo text := lower(trim(COALESCE(p_tipo_documento, '')));
  v_decision text := lower(trim(COALESCE(p_decision, '')));
  v_motivo text := trim(COALESCE(p_motivo, ''));
  v_estado text;
  v_ticket text;
  v_nuevo_estado text;
  v_venta_id bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede resolver resultados inciertos';
  END IF;

  IF v_tipo NOT IN ('comprobante', 'nota_credito', 'guia', 'proceso') THEN
    RAISE EXCEPTION 'Tipo documental inválido';
  END IF;
  IF v_decision NOT IN ('habilitar_reintento', 'mantener_incierto') THEN
    RAISE EXCEPTION 'Decisión inválida';
  END IF;
  IF char_length(v_motivo) < 10 OR char_length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 10 y 500 caracteres';
  END IF;

  IF v_tipo = 'comprobante' THEN
    SELECT estado, ticket_sunat, venta_id INTO v_estado, v_ticket, v_venta_id
    FROM public.comprobantes_electronicos
    WHERE id = p_documento_id FOR UPDATE;
  ELSIF v_tipo = 'nota_credito' THEN
    SELECT estado, ticket_sunat, venta_id INTO v_estado, v_ticket, v_venta_id
    FROM public.notas_credito
    WHERE id = p_documento_id FOR UPDATE;
  ELSIF v_tipo = 'guia' THEN
    SELECT estado, ticket_sunat INTO v_estado, v_ticket
    FROM public.guias_remision
    WHERE id = p_documento_id FOR UPDATE;
  ELSE
    SELECT estado, ticket_sunat INTO v_estado, v_ticket
    FROM public.procesos_tributarios
    WHERE id = p_documento_id FOR UPDATE;
  END IF;

  IF NOT FOUND THEN RAISE EXCEPTION 'Documento no encontrado'; END IF;
  IF v_estado <> 'resultado_incierto' THEN
    RAISE EXCEPTION 'El documento no está en resultado_incierto sino en %', v_estado;
  END IF;

  IF v_decision = 'habilitar_reintento' AND NULLIF(trim(COALESCE(v_ticket, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'El documento tiene ticket. Debe consultarse el ticket y no habilitar un reenvío';
  END IF;

  v_nuevo_estado := CASE
    WHEN v_decision = 'habilitar_reintento' THEN 'pendiente_reintento'
    ELSE 'resultado_incierto'
  END;

  IF v_tipo = 'comprobante' THEN
    UPDATE public.comprobantes_electronicos
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que el documento no fue recibido. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
    UPDATE public.ventas SET estado_facturacion = v_nuevo_estado
    WHERE id = v_venta_id;
  ELSIF v_tipo = 'nota_credito' THEN
    UPDATE public.notas_credito
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que la nota no fue recibida. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
  ELSIF v_tipo = 'guia' THEN
    UPDATE public.guias_remision
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que la GRE no fue recibida. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
  ELSE
    UPDATE public.procesos_tributarios
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que el proceso no fue recibido. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;

    UPDATE public.solicitudes_baja_tributaria
    SET estado = v_nuevo_estado
    WHERE proceso_id = p_documento_id;
    UPDATE public.comprobantes_electronicos ce
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_documento_id AND s.comprobante_id = ce.id;
    UPDATE public.notas_credito nc
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_documento_id AND s.nota_credito_id = nc.id;
  END IF;

  INSERT INTO public.documentos_tributarios_reconciliaciones(
    tipo_documento, documento_id, decision,
    estado_anterior, estado_nuevo, motivo,
    referencia_externa, realizado_por
  ) VALUES (
    v_tipo, p_documento_id, v_decision,
    v_estado, v_nuevo_estado, v_motivo,
    NULLIF(trim(COALESCE(p_referencia_externa, '')), ''), p_usuario_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'tipo_documento', v_tipo,
    'documento_id', p_documento_id,
    'estado_anterior', v_estado,
    'estado', v_nuevo_estado,
    'decision', v_decision
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 9. RPC OPERATIVAS EXISTENTES: NORMALIZACIÓN DE ROLES SIN REESCRIBIR NEGOCIO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_sale_v3(p_request_id uuid, p_cliente_id bigint, p_total numeric, p_fecha timestamp with time zone, p_es_credito boolean, p_monto_abono numeric, p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint, p_vendedor_id bigint, p_tipo_comprobante text, p_descuento_global_porcentaje numeric, p_descuento_global_monto numeric, p_motivo_descuento text, p_subtotal_bruto numeric, p_descuento_autorizado_por bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  -- Datos normalizados
  v_detalles jsonb := COALESCE(p_detalles, '[]'::jsonb);
  v_pagos jsonb := COALESCE(p_pagos, '[]'::jsonb);

  v_tipo_comprobante text :=
    LOWER(TRIM(COALESCE(p_tipo_comprobante, 'ticket_interno')));

  v_fecha timestamp with time zone := COALESCE(p_fecha, now());
  v_fecha_emision date;

  -- Idempotencia
  v_existing_venta_id bigint;
  v_existing_total numeric;
  v_existing_tipo text;
  v_existing_comprobante_id uuid;
  v_existing_serie text;
  v_existing_correlativo bigint;
  v_existing_estado text;

  -- Venta
  v_venta_id bigint;
  v_comprobante_id uuid;
  v_vendedor_id bigint;
  v_vendedor_nombre text;
  v_vendedor_rol text;
  v_autorizado_por bigint;
  v_autorizador_rol text;

  v_estado_venta text;
  v_estado_facturacion text;
  v_saldo numeric(14,2);

  -- Totales
  v_subtotal_calculado numeric(14,2) := 0;
  v_subtotal_reportado numeric(14,2);
  v_descuento_porcentaje numeric(7,4) :=
    COALESCE(p_descuento_global_porcentaje, 0);
  v_descuento_monto numeric(14,2) :=
    COALESCE(p_descuento_global_monto, 0);
  v_descuento_esperado numeric(14,2);
  v_total_final numeric(14,2);

  v_total_pagos numeric(14,2) := 0;
  v_monto_abono numeric(14,2) := ROUND(COALESCE(p_monto_abono, 0), 2);

  v_base_imponible numeric(14,2) := 0;
  v_igv numeric(14,2) := 0;
  v_porcentaje_igv numeric(5,2) := 18.00;
  v_factor_igv numeric;

  -- Configuración
  v_config_encontrada boolean := false;
  v_facturacion_habilitada boolean := false;
  v_precios_incluyen_igv boolean := true;

  v_descuento_sin_autorizacion_hasta numeric(7,4) := 10.0000;
  v_descuento_con_motivo_desde numeric(7,4) := 10.0000;
  v_descuento_con_pin_desde numeric(7,4) := 30.0000;
  v_generar_constancia boolean := true;

  -- Empresa
  v_empresa_ruc text;
  v_empresa_razon_social text;
  v_empresa_nombre_comercial text;
  v_empresa_direccion text;
  v_empresa_ubigeo text;
  v_empresa_departamento text;
  v_empresa_provincia text;
  v_empresa_distrito text;
  v_empresa_cod_local text;
  v_empresa_telefono text;
  v_empresa_logo_url text;

  -- Cliente
  v_cliente_nombre text;
  v_cliente_documento text;
  v_cliente_tipo_doc_db text;
  v_cliente_tipo_sunat text;
  v_cliente_direccion text;

  -- Series
  v_serie_id uuid;
  v_serie text;
  v_correlativo bigint;

  -- Detalles
  v_detalle jsonb;
  v_ordinal integer;
  v_num_detalles integer;

  v_prod_id bigint;
  v_prod_nombre text;
  v_prod_pcs integer;
  v_prod_tipo_venta text;
  v_proveedor_nombre text;
  v_permitir_sin_stock boolean;

  v_almacen_id bigint;
  v_almacen_nombre text;

  v_cantidad_visual integer;
  v_piezas_calculadas integer;
  v_piezas_enviadas integer;

  v_tipo_unidad text;
  v_unidad_label text;

  -- Precio base por pieza/unidad mínima.
  v_precio_unitario numeric(14,4);

  -- Precio de la unidad comercial elegida:
  -- caja completa o unidad suelta.
  v_precio_unitario_comercial numeric(14,4);

  -- Precio de la unidad base de stock después del descuento global.
  v_precio_unitario_final numeric(14,4);
  v_precio_base_esperado numeric(14,4);

  v_subtotal_linea numeric(14,2);
  v_subtotal_linea_reportado numeric(14,2);
  v_descuento_linea numeric(14,2);
  v_subtotal_final_linea numeric(14,2);

  v_descuento_acumulado numeric(14,2) := 0;
  v_subtotal_final_acumulado numeric(14,2) := 0;

  -- Inventario
  v_stock_actual integer;
  v_saldo_actual integer;

  -- Pagos
  v_pago jsonb;
  v_metodo_pago text;
  v_monto_pago numeric(14,2);

  -- Constancia
  v_constancia_id uuid;
  v_constancia_codigo text;

BEGIN
  -- ===========================================================================
  -- 1. VALIDACIONES INICIALES
  -- ===========================================================================

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION
      'request_id es obligatorio para evitar ventas duplicadas';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_request_id::text, 0)
  );

  IF EXISTS (
    SELECT 1
    FROM public.ventas_requests_anulados AS vra
    WHERE vra.request_id = p_request_id
  ) THEN
    RAISE EXCEPTION
      'La venta asociada a este request_id fue anulada y no puede recrearse';
  END IF;

  IF v_tipo_comprobante = 'ticket' THEN
    v_tipo_comprobante := 'ticket_interno';
  END IF;

  IF v_tipo_comprobante NOT IN (
    'ticket_interno',
    'boleta',
    'factura'
  ) THEN
    RAISE EXCEPTION
      'Tipo de comprobante inválido: %',
      v_tipo_comprobante;
  END IF;


  -- Regla comercial: factura y boleta electrónica solo al contado.
  -- Las ventas a crédito continúan disponibles mediante Ticket Interno.
  IF COALESCE(p_es_credito, false)
     AND v_tipo_comprobante IN ('boleta', 'factura') THEN
    RAISE EXCEPTION
      'Las facturas y boletas electrónicas solo pueden emitirse al contado. Para una venta a crédito use Ticket Interno.';
  END IF;

  IF jsonb_typeof(v_detalles) <> 'array'
     OR jsonb_array_length(v_detalles) = 0 THEN
    RAISE EXCEPTION
      'La venta debe contener al menos un producto';
  END IF;

  IF jsonb_typeof(v_pagos) <> 'array' THEN
    RAISE EXCEPTION
      'El parámetro pagos debe ser un arreglo JSON';
  END IF;

  v_num_detalles := jsonb_array_length(v_detalles);
  v_fecha_emision :=
    (v_fecha AT TIME ZONE 'America/Lima')::date;

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN
    IF v_fecha_emision > (now() AT TIME ZONE 'America/Lima')::date THEN
      RAISE EXCEPTION
        'La fecha de emisión electrónica no puede estar en el futuro';
    END IF;

    IF v_tipo_comprobante = 'factura'
       AND v_fecha_emision <
         (now() AT TIME ZONE 'America/Lima')::date - 3 THEN
      RAISE EXCEPTION
        'La factura supera el plazo máximo de tres días calendario posteriores a su fecha de emisión';
    END IF;
  END IF;

  -- ===========================================================================
  -- 2. IDEMPOTENCIA
  -- ===========================================================================

  SELECT
    v.id,
    ROUND(v.total, 2),
    v.tipo_comprobante_solicitado
  INTO
    v_existing_venta_id,
    v_existing_total,
    v_existing_tipo
  FROM public.ventas AS v
  WHERE v.request_id = p_request_id
  LIMIT 1;

  IF FOUND THEN
    IF ABS(v_existing_total - ROUND(COALESCE(p_total, 0), 2)) > 0.02
       OR COALESCE(v_existing_tipo, 'ticket_interno')
            <> v_tipo_comprobante THEN
      RAISE EXCEPTION
        'El request_id ya fue utilizado con datos diferentes';
    END IF;

    SELECT
      ce.id,
      ce.serie,
      ce.correlativo,
      ce.estado
    INTO
      v_existing_comprobante_id,
      v_existing_serie,
      v_existing_correlativo,
      v_existing_estado
    FROM public.comprobantes_electronicos AS ce
    WHERE ce.venta_id = v_existing_venta_id
    ORDER BY ce.created_at DESC
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'venta_id', v_existing_venta_id,
      'comprobante_id', v_existing_comprobante_id,
      'serie', v_existing_serie,
      'correlativo', v_existing_correlativo,
      'estado_facturacion', COALESCE(
        v_existing_estado,
        'no_aplica'
      )
    );
  END IF;

  -- ===========================================================================
  -- 3. CONFIGURACIÓN DEL NEGOCIO
  -- ===========================================================================

  SELECT
    true,
    COALESCE(cn.facturacion_habilitada, false),
    COALESCE(cn.precios_incluyen_igv, true),
    COALESCE(cn.porcentaje_igv, 18.00),

    COALESCE(cn.descuento_sin_autorizacion_hasta, 10.0000),
    COALESCE(cn.descuento_con_motivo_desde, 10.0000),
    COALESCE(cn.descuento_con_pin_desde, 30.0000),
    COALESCE(cn.generar_constancia_descuento, true),

    NULLIF(TRIM(cn.ruc), ''),
    NULLIF(TRIM(cn.razon_social), ''),
    NULLIF(TRIM(cn.nombre_comercial), ''),
    NULLIF(TRIM(cn.direccion), ''),
    NULLIF(TRIM(cn.ubigeo), ''),
    NULLIF(TRIM(cn.departamento), ''),
    NULLIF(TRIM(cn.provincia), ''),
    NULLIF(TRIM(cn.distrito), ''),
    COALESCE(NULLIF(TRIM(cn.cod_local), ''), '0000'),
    NULLIF(TRIM(cn.telefono), ''),
    NULLIF(TRIM(cn.logo_url), '')
  INTO
    v_config_encontrada,
    v_facturacion_habilitada,
    v_precios_incluyen_igv,
    v_porcentaje_igv,

    v_descuento_sin_autorizacion_hasta,
    v_descuento_con_motivo_desde,
    v_descuento_con_pin_desde,
    v_generar_constancia,

    v_empresa_ruc,
    v_empresa_razon_social,
    v_empresa_nombre_comercial,
    v_empresa_direccion,
    v_empresa_ubigeo,
    v_empresa_departamento,
    v_empresa_provincia,
    v_empresa_distrito,
    v_empresa_cod_local,
    v_empresa_telefono,
    v_empresa_logo_url
  FROM public.configuracion_negocio AS cn
  ORDER BY cn.id
  LIMIT 1;

  -- ===========================================================================
  -- 4. VENDEDOR / ACTOR AUTENTICADO
  -- ===========================================================================

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado';
  END IF;

  SELECT
    e.id,
    LOWER(COALESCE(e.rol, 'operador')),
    e.nombre
  INTO
    v_vendedor_id,
    v_vendedor_rol,
    v_vendedor_nombre
  FROM public.empleados AS e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acceso denegado: empleado inactivo o rol no autorizado';
  END IF;

  -- Nunca se confía en p_vendedor_id ni p_descuento_autorizado_por.
  -- El actor real se obtiene exclusivamente de auth.uid().
  v_autorizado_por := NULL;

  -- ===========================================================================
  -- 5. RECALCULAR SUBTOTAL DESDE LOS DETALLES
  -- Usa precio_unitario_comercial, no el precio base por pieza.
  -- ===========================================================================

  FOR v_detalle, v_ordinal IN
    SELECT elemento, ordinalidad::integer
    FROM jsonb_array_elements(v_detalles)
      WITH ORDINALITY AS x(elemento, ordinalidad)
  LOOP
    v_cantidad_visual :=
      COALESCE(
        NULLIF(v_detalle->>'cantidad', '')::numeric,
        0
      )::integer;

    v_precio_unitario :=
      ROUND(
        COALESCE(
          NULLIF(v_detalle->>'precio_unitario', '')::numeric,
          0
        ),
        4
      );

    v_subtotal_linea_reportado :=
      ROUND(
        COALESCE(
          NULLIF(v_detalle->>'subtotal', '')::numeric,
          0
        ),
        2
      );

    IF v_cantidad_visual <= 0 THEN
      RAISE EXCEPTION
        'La cantidad del producto en la posición % debe ser mayor a cero',
        v_ordinal;
    END IF;

    IF v_precio_unitario < 0 THEN
      RAISE EXCEPTION
        'El precio base del producto en la posición % no puede ser negativo',
        v_ordinal;
    END IF;

    v_precio_unitario_comercial :=
      ROUND(
        COALESCE(
          NULLIF(
            v_detalle->>'precio_unitario_comercial',
            ''
          )::numeric,
          CASE
            WHEN v_cantidad_visual > 0
              THEN v_subtotal_linea_reportado / v_cantidad_visual
            ELSE 0
          END
        ),
        4
      );

    IF v_precio_unitario_comercial < 0 THEN
      RAISE EXCEPTION
        'El precio comercial del producto en la posición % no puede ser negativo',
        v_ordinal;
    END IF;

    v_subtotal_linea :=
      ROUND(
        v_cantidad_visual * v_precio_unitario_comercial,
        2
      );

    IF ABS(
      v_subtotal_linea - v_subtotal_linea_reportado
    ) > 0.02 THEN
      RAISE EXCEPTION
        'Subtotal inconsistente en el producto %. Esperado: %, recibido: %',
        v_ordinal,
        v_subtotal_linea,
        v_subtotal_linea_reportado;
    END IF;

    v_subtotal_calculado :=
      ROUND(v_subtotal_calculado + v_subtotal_linea, 2);
  END LOOP;

  IF v_subtotal_calculado <= 0 THEN
    RAISE EXCEPTION
      'El subtotal de la venta debe ser mayor a cero';
  END IF;

  v_subtotal_reportado :=
    ROUND(COALESCE(p_subtotal_bruto, 0), 2);

  IF v_subtotal_reportado > 0
     AND ABS(
       v_subtotal_reportado - v_subtotal_calculado
     ) > 0.02 THEN
    RAISE EXCEPTION
      'El subtotal bruto no coincide. Calculado: %, recibido: %',
      v_subtotal_calculado,
      v_subtotal_reportado;
  END IF;

  -- ===========================================================================
  -- 6. DESCUENTO GLOBAL
  -- ===========================================================================

  IF v_descuento_porcentaje < 0
     OR v_descuento_porcentaje > 100 THEN
    RAISE EXCEPTION
      'El descuento porcentual debe estar entre 0 y 100';
  END IF;

  IF v_descuento_monto < 0 THEN
    RAISE EXCEPTION
      'El monto de descuento no puede ser negativo';
  END IF;

  IF v_descuento_porcentaje > 0
     AND v_descuento_monto > 0 THEN

    v_descuento_esperado :=
      ROUND(
        v_subtotal_calculado
        * v_descuento_porcentaje
        / 100,
        2
      );

    IF ABS(
      v_descuento_esperado - v_descuento_monto
    ) > 0.02 THEN
      RAISE EXCEPTION
        'El porcentaje y monto del descuento no coinciden';
    END IF;

  ELSIF v_descuento_porcentaje > 0 THEN

    v_descuento_monto :=
      ROUND(
        v_subtotal_calculado
        * v_descuento_porcentaje
        / 100,
        2
      );

  ELSIF v_descuento_monto > 0 THEN

    v_descuento_porcentaje :=
      ROUND(
        v_descuento_monto
        / v_subtotal_calculado
        * 100,
        4
      );

  ELSE
    v_descuento_porcentaje := 0;
    v_descuento_monto := 0;
  END IF;

  IF v_descuento_monto > v_subtotal_calculado THEN
    RAISE EXCEPTION
      'El descuento no puede superar el subtotal de la venta';
  END IF;

  v_total_final :=
    ROUND(
      v_subtotal_calculado - v_descuento_monto,
      2
    );

  IF v_total_final <= 0 THEN
    RAISE EXCEPTION
      'El descuento no puede dejar la venta en S/ 0.00';
  END IF;

  IF ABS(
    v_total_final - ROUND(COALESCE(p_total, 0), 2)
  ) > 0.02 THEN
    RAISE EXCEPTION
      'El total enviado no coincide. Calculado: %, recibido: %',
      v_total_final,
      ROUND(COALESCE(p_total, 0), 2);
  END IF;

  -- ===========================================================================
  -- 7. AUTORIZACIÓN DE DESCUENTOS
  -- ===========================================================================

  IF v_descuento_porcentaje >= v_descuento_con_motivo_desde
     AND COALESCE(TRIM(p_motivo_descuento), '') = '' THEN
    RAISE EXCEPTION
      'Debe registrar el motivo del descuento';
  END IF;

  IF v_descuento_porcentaje
       > v_descuento_sin_autorizacion_hasta THEN

    IF v_autorizado_por IS NULL
       AND v_vendedor_id IS NOT NULL
       AND v_vendedor_rol = 'admin' THEN
      v_autorizado_por := v_vendedor_id;
    END IF;

    IF v_autorizado_por IS NULL THEN
      RAISE EXCEPTION
        'El descuento de % %% requiere autorización de un administrador',
        v_descuento_porcentaje;
    END IF;

    SELECT LOWER(COALESCE(e.rol, 'operador'))
    INTO v_autorizador_rol
    FROM public.empleados AS e
    WHERE e.id = v_autorizado_por
      AND COALESCE(e.activo, true) = true;

    IF NOT FOUND
       OR v_autorizador_rol <> 'admin' THEN
      RAISE EXCEPTION
        'El usuario autorizador no es un administrador activo';
    END IF;
  END IF;

  -- ===========================================================================
  -- 8. PAGOS
  -- ===========================================================================

  FOR v_pago IN
    SELECT value
    FROM jsonb_array_elements(v_pagos)
  LOOP
    v_metodo_pago :=
      TRIM(COALESCE(v_pago->>'metodo', ''));

    v_monto_pago :=
      ROUND(
        COALESCE(
          NULLIF(v_pago->>'monto', '')::numeric,
          0
        ),
        2
      );

    IF v_metodo_pago = '' THEN
      RAISE EXCEPTION
        'Todos los pagos deben tener un método';
    END IF;

    IF v_monto_pago <= 0 THEN
      RAISE EXCEPTION
        'Todos los pagos deben tener un monto mayor a cero';
    END IF;

    v_total_pagos :=
      ROUND(v_total_pagos + v_monto_pago, 2);
  END LOOP;

  IF COALESCE(p_es_credito, false) = false THEN
    IF ABS(v_total_pagos - v_total_final) > 0.02 THEN
      RAISE EXCEPTION
        'En venta al contado los pagos deben sumar exactamente %. Recibido: %',
        v_total_final,
        v_total_pagos;
    END IF;

    v_monto_abono := v_total_final;
    v_saldo := 0;
    v_estado_venta := 'pagado';

  ELSE
    IF v_monto_abono < 0
       OR v_monto_abono > v_total_final THEN
      RAISE EXCEPTION
        'El abono debe estar entre S/ 0.00 y S/ %',
        v_total_final;
    END IF;

    IF ABS(v_total_pagos - v_monto_abono) > 0.02 THEN
      RAISE EXCEPTION
        'Los pagos del crédito deben coincidir con el abono inicial';
    END IF;

    v_saldo :=
      ROUND(v_total_final - v_monto_abono, 2);

    v_estado_venta :=
      CASE
        WHEN v_saldo <= 0.01 THEN 'pagado'
        ELSE 'pendiente'
      END;
  END IF;

  -- ===========================================================================
  -- 9. CLIENTE
  -- ===========================================================================

  IF p_cliente_id IS NOT NULL THEN
    SELECT
      NULLIF(TRIM(c.nombre), ''),
      NULLIF(TRIM(c.dni_ruc), ''),
      LOWER(NULLIF(TRIM(c.tipo_doc), '')),
      NULLIF(TRIM(c.direccion), '')
    INTO
      v_cliente_nombre,
      v_cliente_documento,
      v_cliente_tipo_doc_db,
      v_cliente_direccion
    FROM public.clientes AS c
    WHERE c.id = p_cliente_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El cliente seleccionado no existe';
    END IF;
  ELSE
    v_cliente_nombre := 'CLIENTE GENERAL';
    v_cliente_documento := NULL;
    v_cliente_tipo_doc_db := NULL;
    v_cliente_direccion := NULL;
  END IF;

  v_cliente_nombre :=
    COALESCE(v_cliente_nombre, 'CLIENTE GENERAL');

  -- ===========================================================================
  -- 10. VALIDACIONES TRIBUTARIAS
  -- ===========================================================================

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN

    IF v_config_encontrada = false THEN
      RAISE EXCEPTION
        'No existe configuración del negocio';
    END IF;

    IF v_facturacion_habilitada = false THEN
      RAISE EXCEPTION
        'La facturación electrónica todavía está deshabilitada';
    END IF;

    IF v_precios_incluyen_igv = false THEN
      RAISE EXCEPTION
        'process_sale_v3 requiere precios que ya incluyan IGV';
    END IF;

    IF v_empresa_ruc IS NULL
       OR v_empresa_ruc !~ '^[0-9]{11}$' THEN
      RAISE EXCEPTION
        'El RUC del negocio debe tener exactamente 11 dígitos';
    END IF;

    IF v_empresa_razon_social IS NULL THEN
      RAISE EXCEPTION
        'Falta la razón social del negocio';
    END IF;

    IF v_empresa_direccion IS NULL THEN
      RAISE EXCEPTION
        'Falta la dirección fiscal del negocio';
    END IF;

    IF v_empresa_ubigeo IS NULL
       OR v_empresa_ubigeo !~ '^[0-9]{6}$' THEN
      RAISE EXCEPTION
        'El ubigeo del negocio debe tener 6 dígitos';
    END IF;

    IF v_empresa_departamento IS NULL
       OR v_empresa_provincia IS NULL
       OR v_empresa_distrito IS NULL THEN
      RAISE EXCEPTION
        'Falta completar departamento, provincia o distrito';
    END IF;

    IF v_tipo_comprobante = 'factura' THEN
      IF v_cliente_documento IS NULL
         OR v_cliente_documento !~ '^[0-9]{11}$' THEN
        RAISE EXCEPTION
          'La factura requiere un cliente con RUC de 11 dígitos';
      END IF;

      v_cliente_tipo_sunat := '6';

    ELSE
      IF v_total_final > 700.00 THEN
        IF v_cliente_documento IS NULL
           OR v_cliente_documento !~ '^[0-9]{8}$' THEN
          RAISE EXCEPTION
            'Para boletas mayores a S/ 700.00, el DNI de 8 dígitos es obligatorio';
        END IF;

        IF NULLIF(TRIM(COALESCE(v_cliente_nombre, '')), '') IS NULL
           OR UPPER(TRIM(v_cliente_nombre)) = 'CLIENTE GENERAL' THEN
          RAISE EXCEPTION
            'Para boletas mayores a S/ 700.00, el nombre completo del cliente es obligatorio';
        END IF;
      END IF;

      IF v_cliente_documento IS NULL
         OR v_cliente_documento = ''
         OR v_cliente_documento = '00000000' THEN

        v_cliente_tipo_sunat := '0';
        v_cliente_documento := '0';

      ELSIF v_cliente_documento ~ '^[0-9]{8}$' THEN
        v_cliente_tipo_sunat := '1';

      ELSE
        RAISE EXCEPTION
          'La boleta requiere DNI de 8 dígitos o cliente sin documento';
      END IF;
    END IF;
  ELSE
    IF v_cliente_documento ~ '^[0-9]{11}$' THEN
      v_cliente_tipo_sunat := '6';
    ELSIF v_cliente_documento ~ '^[0-9]{8}$' THEN
      v_cliente_tipo_sunat := '1';
    ELSE
      v_cliente_tipo_sunat := '0';
    END IF;
  END IF;

  -- ===========================================================================
  -- 11. BASE E IGV
  -- ===========================================================================

  v_factor_igv :=
    1 + (v_porcentaje_igv / 100);

  v_base_imponible :=
    ROUND(v_total_final / v_factor_igv, 2);

  v_igv :=
    ROUND(v_total_final - v_base_imponible, 2);

  v_estado_facturacion :=
    CASE
      WHEN v_tipo_comprobante = 'ticket_interno'
        THEN 'no_aplica'
      ELSE 'pendiente'
    END;

  -- ===========================================================================
  -- 12. CREAR VENTA
  -- ===========================================================================

  INSERT INTO public.ventas (
    cliente_id,
    total,
    estado,
    saldo,
    fecha,
    tipo_comprobante_solicitado,
    estado_facturacion,
    subtotal_bruto,
    descuento_global_porcentaje,
    descuento_global_monto,
    motivo_descuento,
    vendedor_id,
    request_id,
    descuento_autorizado_por,
    descuento_autorizado_at
  )
  VALUES (
    p_cliente_id,
    v_total_final,
    v_estado_venta,
    v_saldo,
    v_fecha,
    v_tipo_comprobante,
    v_estado_facturacion,
    v_subtotal_calculado,
    v_descuento_porcentaje,
    v_descuento_monto,
    NULLIF(TRIM(p_motivo_descuento), ''),
    v_vendedor_id,
    p_request_id,
    v_autorizado_por,
    CASE
      WHEN v_autorizado_por IS NOT NULL THEN now()
      ELSE NULL
    END
  )
  RETURNING id INTO v_venta_id;

  -- ===========================================================================
  -- 13. COTIZACIÓN
  -- ===========================================================================

  IF p_cotizacion_id IS NOT NULL THEN
    UPDATE public.cotizaciones
    SET estado = 'aprobada'
    WHERE id = p_cotizacion_id;
  END IF;

  -- ===========================================================================
  -- 14. PAGOS
  -- ===========================================================================

  FOR v_pago IN
    SELECT value
    FROM jsonb_array_elements(v_pagos)
  LOOP
    v_metodo_pago :=
      TRIM(v_pago->>'metodo');

    v_monto_pago :=
      ROUND((v_pago->>'monto')::numeric, 2);

    INSERT INTO public.pagos_venta (
      venta_id,
      metodo,
      monto,
      fecha
    )
    VALUES (
      v_venta_id,
      v_metodo_pago,
      v_monto_pago,
      v_fecha
    );
  END LOOP;

  -- ===========================================================================
  -- 15. DETALLES, STOCK Y KARDEX
  -- ===========================================================================

  FOR v_detalle, v_ordinal IN
    SELECT elemento, ordinalidad::integer
    FROM jsonb_array_elements(v_detalles)
      WITH ORDINALITY AS x(elemento, ordinalidad)
  LOOP
    v_prod_id :=
      (v_detalle->>'producto_id')::bigint;

    v_almacen_id :=
      (v_detalle->>'almacen_id')::bigint;

    v_cantidad_visual :=
      (v_detalle->>'cantidad')::numeric::integer;

    v_precio_unitario :=
      ROUND(
        (v_detalle->>'precio_unitario')::numeric,
        4
      );

    v_subtotal_linea_reportado :=
      ROUND(
        (v_detalle->>'subtotal')::numeric,
        2
      );

    v_precio_unitario_comercial :=
      ROUND(
        COALESCE(
          NULLIF(
            v_detalle->>'precio_unitario_comercial',
            ''
          )::numeric,
          CASE
            WHEN v_cantidad_visual > 0
              THEN v_subtotal_linea_reportado / v_cantidad_visual
            ELSE 0
          END
        ),
        4
      );

    v_tipo_unidad :=
      LOWER(TRIM(COALESCE(v_detalle->>'tipo_unidad', 'unidad')));

    IF v_tipo_unidad IN ('cajas', 'box', 'bx') THEN
      v_tipo_unidad := 'caja';
    ELSIF v_tipo_unidad IN ('paquetes', 'paq', 'pack', 'pk') THEN
      v_tipo_unidad := 'paquete';
    ELSIF v_tipo_unidad IN (
      'unidades', 'und', 'niu', 'pieza', 'piezas'
    ) THEN
      v_tipo_unidad := 'unidad';
    END IF;

    IF v_tipo_unidad NOT IN ('caja', 'paquete', 'unidad') THEN
      RAISE EXCEPTION
        'Tipo de unidad inválido en el producto %',
        v_prod_id;
    END IF;

    SELECT
      p.nombre,
      GREATEST(COALESCE(p.cantidad_por_caja, 1), 1),
      LOWER(COALESCE(p.tipo_venta, 'ambos')),
      COALESCE(pr.nombre, 'Generico'),
      COALESCE(p.permitir_sin_stock, false)
    INTO
      v_prod_nombre,
      v_prod_pcs,
      v_prod_tipo_venta,
      v_proveedor_nombre,
      v_permitir_sin_stock
    FROM public.productos AS p
    LEFT JOIN public.proveedores AS pr
      ON pr.id = p.proveedor_id
    WHERE p.id = v_prod_id
      AND COALESCE(p.activo, true) = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El producto % no existe o está inactivo',
        v_prod_id;
    END IF;

    IF v_prod_tipo_venta IN ('paquetes', 'paquete')
       AND v_tipo_unidad <> 'paquete' THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por paquetes',
        v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta = 'caja_paquetes'
       AND v_tipo_unidad NOT IN ('caja', 'paquete') THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por caja o paquete',
        v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta = 'caja_unidades'
       AND v_tipo_unidad NOT IN ('caja', 'unidad') THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por caja o unidad',
        v_prod_nombre;
    END IF;

    -- Compatibilidad histórica.
    IF v_prod_tipo_venta IN ('solo_cajas', 'caja')
       AND v_tipo_unidad <> 'caja' THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por cajas', v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta IN ('solo_unidades', 'unidad')
       AND v_tipo_unidad <> 'unidad' THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por unidades', v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta IN ('ambos', 'caja_unidad', 'cajas_unidades')
       AND v_tipo_unidad NOT IN ('caja', 'unidad') THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por caja o unidad', v_prod_nombre;
    END IF;

    -- La función central calcula la cantidad base real de inventario.
    v_piezas_calculadas :=
      public.calcular_piezas_reales_stock(
        v_prod_tipo_venta,
        v_tipo_unidad,
        v_cantidad_visual,
        v_prod_pcs
      );

    IF v_detalle ? 'piezas_reales'
       AND NULLIF(v_detalle->>'piezas_reales', '') IS NOT NULL THEN

      v_piezas_enviadas :=
        (v_detalle->>'piezas_reales')::numeric::integer;

      IF v_piezas_enviadas <> v_piezas_calculadas THEN
        RAISE EXCEPTION
          'Cantidad de stock inconsistente para %. Calculado: %, recibido: %',
          v_prod_nombre,
          v_piezas_calculadas,
          v_piezas_enviadas;
      END IF;
    END IF;

    v_precio_base_esperado :=
      CASE
        WHEN v_piezas_calculadas > 0
          THEN ROUND(v_subtotal_linea_reportado / v_piezas_calculadas, 4)
        ELSE 0
      END;

    IF ABS(v_precio_unitario - v_precio_base_esperado) > 0.02 THEN
      RAISE EXCEPTION
        'Precio base de stock inconsistente para %. Esperado: %, recibido: %',
        v_prod_nombre,
        v_precio_base_esperado,
        v_precio_unitario;
    END IF;

    -- Validación económica independiente de la validación de stock.
    v_subtotal_linea :=
      ROUND(
        v_cantidad_visual * v_precio_unitario_comercial,
        2
      );

    IF ABS(
      v_subtotal_linea - v_subtotal_linea_reportado
    ) > 0.02 THEN
      RAISE EXCEPTION
        'Subtotal comercial inconsistente para %. Esperado: %, recibido: %',
        v_prod_nombre,
        v_subtotal_linea,
        v_subtotal_linea_reportado;
    END IF;

    -- Distribución proporcional del descuento global.
    IF v_descuento_monto > 0 THEN
      IF v_ordinal = v_num_detalles THEN
        v_descuento_linea :=
          ROUND(
            v_descuento_monto - v_descuento_acumulado,
            2
          );
      ELSE
        v_descuento_linea :=
          ROUND(
            v_descuento_monto
            * v_subtotal_linea
            / v_subtotal_calculado,
            2
          );
      END IF;
    ELSE
      v_descuento_linea := 0;
    END IF;

    IF v_descuento_linea < 0
       OR v_descuento_linea > v_subtotal_linea THEN
      RAISE EXCEPTION
        'El descuento distribuido es inválido para %',
        v_prod_nombre;
    END IF;

    v_subtotal_final_linea :=
      ROUND(
        v_subtotal_linea - v_descuento_linea,
        2
      );

    v_descuento_acumulado :=
      ROUND(
        v_descuento_acumulado + v_descuento_linea,
        2
      );

    v_subtotal_final_acumulado :=
      ROUND(
        v_subtotal_final_acumulado
        + v_subtotal_final_linea,
        2
      );

    v_precio_unitario_final :=
      CASE
        WHEN v_piezas_calculadas > 0
          THEN ROUND(
            v_subtotal_final_linea / v_piezas_calculadas,
            4
          )
        ELSE 0
      END;

    SELECT a.nombre
    INTO v_almacen_nombre
    FROM public.almacenes AS a
    WHERE a.id = v_almacen_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El almacén % no existe',
        v_almacen_id;
    END IF;

    SELECT COALESCE(ia.cantidad, 0)
    INTO v_stock_actual
    FROM public.inventario_almacen AS ia
    WHERE ia.producto_id = v_prod_id
      AND ia.almacen_id = v_almacen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      IF v_permitir_sin_stock THEN
        INSERT INTO public.inventario_almacen (
          producto_id,
          almacen_id,
          cantidad
        )
        VALUES (
          v_prod_id,
          v_almacen_id,
          0
        )
        ON CONFLICT (producto_id, almacen_id)
        DO NOTHING;

        SELECT COALESCE(ia.cantidad, 0)
        INTO v_stock_actual
        FROM public.inventario_almacen AS ia
        WHERE ia.producto_id = v_prod_id
          AND ia.almacen_id = v_almacen_id
        FOR UPDATE;
      ELSE
        RAISE EXCEPTION
          'No existe inventario para % en el almacén %',
          v_prod_nombre,
          v_almacen_nombre;
      END IF;
    END IF;

    IF v_stock_actual < v_piezas_calculadas
       AND v_permitir_sin_stock = false THEN
      RAISE EXCEPTION
        'Stock insuficiente para %. Disponible: %, requerido: %',
        v_prod_nombre,
        v_stock_actual,
        v_piezas_calculadas;
    END IF;

    UPDATE public.inventario_almacen
    SET cantidad =
      COALESCE(cantidad, 0) - v_piezas_calculadas
    WHERE producto_id = v_prod_id
      AND almacen_id = v_almacen_id
    RETURNING cantidad INTO v_saldo_actual;

    INSERT INTO public.detalle_ventas (
      venta_id,
      producto_id,
      cantidad,
      piezas_reales,
      precio_unitario,
      precio_unitario_comercial,
      subtotal,
      almacen_id,
      tipo_unidad,
      descuento_global_asignado,
      subtotal_final,
      tipo_venta_snapshot,
      pcs_snapshot,
      unidad_base_snapshot
    )
    VALUES (
      v_venta_id,
      v_prod_id,
      v_cantidad_visual,
      v_piezas_calculadas,
      v_precio_unitario,
      v_precio_unitario_comercial,
      v_subtotal_linea,
      v_almacen_id,
      v_tipo_unidad,
      v_descuento_linea,
      v_subtotal_final_linea,
      UPPER(v_prod_tipo_venta),
      v_prod_pcs,
      CASE
        WHEN v_prod_tipo_venta IN ('paquetes', 'paquete', 'caja_paquetes')
          THEN 'Paquete'
        WHEN v_prod_tipo_venta IN ('solo_cajas', 'caja')
          THEN 'Caja'
        ELSE 'Unidad'
      END
    );

    v_unidad_label :=
      CASE
        WHEN v_prod_tipo_venta IN ('paquetes', 'paquete', 'caja_paquetes')
          THEN 'Paquete'
        WHEN v_prod_tipo_venta IN ('solo_cajas', 'caja')
          THEN 'Caja'
        ELSE 'Unidad'
      END;

    INSERT INTO public.inventario_movimientos (
      fecha,
      producto_id,
      producto_nombre,
      pcs,
      proveedor,
      tipo,
      saldo,
      almacen_id,
      almacen_nombre,
      observaciones,
      salida_cant,
      salida_und,
      salida_cliente,
      salida_p_unit,
      salida_total,
      venta_id,
      venta_id_original,
      vendedor_id,
      vendedor_nombre_snapshot,
      tipo_venta_snapshot,
      unidad_base_snapshot,
      request_id
    )
    VALUES (
      v_fecha,
      v_prod_id,
      v_prod_nombre,
      v_prod_pcs,
      v_proveedor_nombre,
      'SALIDA',
      v_saldo_actual,
      v_almacen_id,
      COALESCE(v_almacen_nombre, ''),
      'Venta #' || v_venta_id,
      v_piezas_calculadas,
      v_unidad_label,
      v_cliente_nombre,
      v_precio_unitario_final,
      v_subtotal_final_linea,
      v_venta_id,
      v_venta_id,
      v_vendedor_id,
      v_vendedor_nombre,
      UPPER(v_prod_tipo_venta),
      v_unidad_label,
      p_request_id
    );
  END LOOP;

  IF ABS(
    v_descuento_acumulado - v_descuento_monto
  ) > 0.02 THEN
    RAISE EXCEPTION
      'Error distribuyendo el descuento. Esperado: %, distribuido: %',
      v_descuento_monto,
      v_descuento_acumulado;
  END IF;

  IF ABS(
    v_subtotal_final_acumulado - v_total_final
  ) > 0.02 THEN
    RAISE EXCEPTION
      'Error en los totales finales. Esperado: %, calculado: %',
      v_total_final,
      v_subtotal_final_acumulado;
  END IF;

  -- ===========================================================================
  -- 16. CONSTANCIA DE DESCUENTO
  -- ===========================================================================

  IF v_descuento_monto > 0
     AND v_generar_constancia = true THEN

    v_constancia_codigo :=
      'DESC-'
      || TO_CHAR(
        v_fecha AT TIME ZONE 'America/Lima',
        'YYYYMMDD'
      )
      || '-'
      || LPAD(v_venta_id::text, 8, '0');

    INSERT INTO public.constancias_descuento (
      venta_id,
      comprobante_id,
      codigo,
      subtotal_bruto,
      descuento_porcentaje,
      descuento_monto,
      total_final,
      motivo,
      aplicado_por,
      autorizado_por,
      autorizado_at
    )
    VALUES (
      v_venta_id,
      NULL,
      v_constancia_codigo,
      v_subtotal_calculado,
      v_descuento_porcentaje,
      v_descuento_monto,
      v_total_final,
      NULLIF(TRIM(p_motivo_descuento), ''),
      v_vendedor_id,
      v_autorizado_por,
      CASE
        WHEN v_autorizado_por IS NOT NULL THEN now()
        ELSE NULL
      END
    )
    RETURNING id INTO v_constancia_id;
  END IF;

  -- ===========================================================================
  -- 17. COMPROBANTE ELECTRÓNICO PENDIENTE
  -- ===========================================================================

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN

    SELECT
      sc.id,
      sc.serie
    INTO
      v_serie_id,
      v_serie
    FROM public.series_comprobantes AS sc
    WHERE sc.tipo_documento_sunat = v_tipo_comprobante
      AND sc.activo = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'No existe una serie activa para %',
        v_tipo_comprobante;
    END IF;

    UPDATE public.series_comprobantes
    SET ultimo_correlativo = ultimo_correlativo + 1
    WHERE id = v_serie_id
    RETURNING ultimo_correlativo
    INTO v_correlativo;

    INSERT INTO public.comprobantes_electronicos (
      venta_id,
      tipo_documento_sunat,
      serie,
      correlativo,
      fecha_emision,
      fecha_emision_ts,
      moneda,
      estado,
      subtotal_bruto,
      descuento_global_porcentaje,
      descuento_global_monto,
      base_imponible,
      igv,
      total,
      cliente_tipo_documento,
      cliente_numero_documento,
      cliente_razon_social,
      cliente_direccion,
      empresa_ruc,
      empresa_razon_social,
      empresa_nombre_comercial,
      empresa_direccion,
      empresa_ubigeo,
      empresa_departamento,
      empresa_provincia,
      empresa_distrito,
      empresa_cod_local,
      empresa_telefono,
      empresa_logo_url,
      request_id
    )
    VALUES (
      v_venta_id,
      v_tipo_comprobante,
      v_serie,
      v_correlativo,
      v_fecha_emision,
      v_fecha,
      'PEN',
      'pendiente',
      v_subtotal_calculado,
      v_descuento_porcentaje,
      v_descuento_monto,
      v_base_imponible,
      v_igv,
      v_total_final,
      v_cliente_tipo_sunat,
      v_cliente_documento,
      v_cliente_nombre,
      v_cliente_direccion,
      v_empresa_ruc,
      v_empresa_razon_social,
      COALESCE(
        v_empresa_nombre_comercial,
        v_empresa_razon_social
      ),
      v_empresa_direccion,
      v_empresa_ubigeo,
      v_empresa_departamento,
      v_empresa_provincia,
      v_empresa_distrito,
      COALESCE(v_empresa_cod_local, '0000'),
      v_empresa_telefono,
      v_empresa_logo_url,
      p_request_id
    )
    RETURNING id INTO v_comprobante_id;

    IF v_constancia_id IS NOT NULL THEN
      UPDATE public.constancias_descuento AS cd
      SET comprobante_id = v_comprobante_id
      WHERE cd.id = v_constancia_id;
    END IF;
  END IF;

  -- ===========================================================================
  -- 18. RESPUESTA
  -- ===========================================================================

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'venta_id', v_venta_id,
    'request_id', p_request_id,
    'subtotal_bruto', v_subtotal_calculado,
    'descuento_global_porcentaje', v_descuento_porcentaje,
    'descuento_global_monto', v_descuento_monto,
    'total', v_total_final,
    'estado_venta', v_estado_venta,
    'saldo', v_saldo,
    'comprobante_id', v_comprobante_id,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'estado_facturacion', v_estado_facturacion,
    'constancia_descuento_id', v_constancia_id,
    'constancia_descuento_codigo', v_constancia_codigo
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.crear_nota_credito_v1(p_request_id uuid, p_comprobante_id uuid, p_motivo_codigo text, p_motivo_descripcion text DEFAULT NULL::text, p_detalles jsonb DEFAULT '[]'::jsonb, p_monto_descuento numeric DEFAULT NULL::numeric, p_reponer_stock boolean DEFAULT true, p_fecha timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_nota_id uuid;
  v_existing record;
  v_tipo_serie text;
  v_serie text;
  v_correlativo bigint;
  v_tipo_doc_afectado text;
  v_codigo text := TRIM(COALESCE(p_motivo_codigo, ''));
  v_descripcion text;
  v_fecha_ts timestamp with time zone := COALESCE(p_fecha, now());
  v_fecha date;
  v_afecta_stock boolean;
  v_afecta_dinero boolean;
  v_repone_stock boolean;
  v_total numeric(14,2) := 0;
  v_base numeric(14,2) := 0;
  v_igv numeric(14,2) := 0;
  v_total_comprometido numeric(14,2) := 0;
  v_disponible numeric(14,2) := 0;
  v_item jsonb;
  v_det record;
  v_cantidad integer;
  v_reservado integer;
  v_piezas integer;
  v_linea_total numeric(14,2);
  v_linea_base numeric(14,2);
  v_linea_igv numeric(14,2);
  v_descripcion_corregida text;
  v_last_detail_id uuid;
  v_diff numeric(14,2);
  v_unidad_sunat text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION
      'Solo un administrador u operador activo puede emitir notas de crédito';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio';
  END IF;

  IF p_comprobante_id IS NULL THEN
    RAISE EXCEPTION 'comprobante_id es obligatorio';
  END IF;

  IF v_codigo NOT IN ('01', '03', '04', '07') THEN
    RAISE EXCEPTION 'Motivo de nota de crédito no permitido: %', v_codigo;
  END IF;

  IF jsonb_typeof(COALESCE(p_detalles, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'detalles debe ser un arreglo JSON';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT *
  INTO v_existing
  FROM public.notas_credito
  WHERE request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'nota_credito_id', v_existing.id,
      'serie', v_existing.serie,
      'correlativo', v_existing.correlativo,
      'estado', v_existing.estado
    );
  END IF;

  SELECT
    ce.*,
    v.total AS venta_total,
    v.estado AS venta_estado,
    v.estado_tributario,
    v.cliente_id
  INTO v_comp
  FROM public.comprobantes_electronicos AS ce
  JOIN public.ventas AS v ON v.id = ce.venta_id
  WHERE ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) <> 'aceptado' THEN
    RAISE EXCEPTION
      'Solo se puede emitir una nota de crédito para un comprobante aceptado';
  END IF;

  IF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) = 'factura' THEN
    v_tipo_doc_afectado := '01';
    v_tipo_serie := 'nota_credito_factura';
    v_serie := 'FC01';
  ELSIF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) = 'boleta' THEN
    v_tipo_doc_afectado := '03';
    v_tipo_serie := 'nota_credito_boleta';
    v_serie := 'BC01';
  ELSE
    RAISE EXCEPTION
      'El comprobante original no es una factura o boleta electrónica';
  END IF;

  -- SUNAT no permite utilizar el motivo 04 (descuento global)
  -- para boletas de venta electrónica emitidas a consumidores finales.
  IF v_tipo_doc_afectado = '03' AND v_codigo = '04' THEN
    RAISE EXCEPTION
      'SUNAT no permite el motivo 04 (descuento global) para boletas de venta electrónica';
  END IF;

  v_descripcion := COALESCE(
    NULLIF(TRIM(p_motivo_descripcion), ''),
    CASE v_codigo
      WHEN '01' THEN 'ANULACION DE LA OPERACION'
      WHEN '03' THEN 'CORRECCION POR ERROR EN LA DESCRIPCION'
      WHEN '04' THEN 'DESCUENTO GLOBAL'
      WHEN '07' THEN 'DEVOLUCION POR ITEM'
    END
  );

  v_afecta_stock := v_codigo IN ('01', '07');
  v_afecta_dinero := v_codigo IN ('01', '04', '07');

  -- Reglas confirmadas del negocio:
  -- 01 (anulación total) y 07 (devolución por ítem) siempre reponen stock.
  -- El parámetro se conserva únicamente por compatibilidad de la firma RPC.
  v_repone_stock := v_afecta_stock;
  v_fecha := (v_fecha_ts AT TIME ZONE 'America/Lima')::date;

  IF v_fecha > (now() AT TIME ZONE 'America/Lima')::date THEN
    RAISE EXCEPTION
      'La fecha de emisión de la nota no puede estar en el futuro';
  END IF;

  IF v_tipo_doc_afectado = '01'
     AND v_fecha < (now() AT TIME ZONE 'America/Lima')::date - 3 THEN
    RAISE EXCEPTION
      'La nota vinculada a factura supera el plazo máximo de tres días calendario posteriores a su fecha de emisión';
  END IF;

  SELECT COALESCE(SUM(nc.total), 0)
  INTO v_total_comprometido
  FROM public.notas_credito AS nc
  WHERE nc.comprobante_id = p_comprobante_id
    AND nc.afecta_dinero = true
    AND nc.estado IN (
      'pendiente_envio',
      'procesando',
      'pendiente_reintento',
      'resultado_incierto',
      'aceptado'
    );

  v_disponible := GREATEST(
    ROUND(COALESCE(v_comp.total, 0) - v_total_comprometido, 2),
    0
  );

  IF v_codigo = '01' AND v_total_comprometido > 0.01 THEN
    RAISE EXCEPTION
      'No se puede hacer anulación total porque ya existen devoluciones o descuentos por S/ %',
      v_total_comprometido;
  END IF;

  UPDATE public.series_comprobantes
  SET
    ultimo_correlativo = ultimo_correlativo + 1,
    updated_at = now()
  WHERE tipo_documento_sunat = v_tipo_serie
    AND serie = v_serie
    AND activo = true
  RETURNING ultimo_correlativo INTO v_correlativo;

  IF v_correlativo IS NULL THEN
    RAISE EXCEPTION 'No existe una serie activa para %', v_tipo_serie;
  END IF;

  INSERT INTO public.notas_credito(
    request_id,
    comprobante_id,
    venta_id,
    tipo_origen,
    tipo_doc_afectado,
    serie_afectada,
    correlativo_afectado,
    motivo_codigo,
    motivo_descripcion,
    serie,
    correlativo,
    fecha_emision,
    fecha_emision_ts,
    estado,
    afecta_stock,
    afecta_dinero,
    reponer_stock,

    cliente_tipo_documento,
    cliente_numero_documento,
    cliente_razon_social,
    cliente_direccion,

    empresa_ruc,
    empresa_razon_social,
    empresa_nombre_comercial,
    empresa_direccion,
    empresa_ubigeo,
    empresa_departamento,
    empresa_provincia,
    empresa_distrito,
    empresa_cod_local,
    empresa_telefono,
    empresa_logo_url,
    creado_por
  )
  VALUES (
    p_request_id,
    p_comprobante_id,
    v_comp.venta_id,
    LOWER(v_comp.tipo_documento_sunat),
    v_tipo_doc_afectado,
    v_comp.serie,
    v_comp.correlativo,
    v_codigo,
    v_descripcion,
    v_serie,
    v_correlativo,
    v_fecha,
    v_fecha_ts,
    'pendiente_envio',
    v_afecta_stock,
    v_afecta_dinero,
    v_repone_stock,

    v_comp.cliente_tipo_documento,
    v_comp.cliente_numero_documento,
    v_comp.cliente_razon_social,
    v_comp.cliente_direccion,

    v_comp.empresa_ruc,
    v_comp.empresa_razon_social,
    v_comp.empresa_nombre_comercial,
    v_comp.empresa_direccion,
    v_comp.empresa_ubigeo,
    v_comp.empresa_departamento,
    v_comp.empresa_provincia,
    v_comp.empresa_distrito,
    v_comp.empresa_cod_local,
    v_comp.empresa_telefono,
    v_comp.empresa_logo_url,
    auth.uid()
  )
  RETURNING id INTO v_nota_id;

  -- ---------------------------------------------------------------------------
  -- 01: ANULACIÓN TOTAL
  -- ---------------------------------------------------------------------------
  IF v_codigo = '01' THEN
    FOR v_det IN
      SELECT
        dv.*,
        p.codigo,
        p.nombre,
        COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
      FROM public.detalle_ventas AS dv
      JOIN public.productos AS p ON p.id = dv.producto_id
      WHERE dv.venta_id = v_comp.venta_id
      ORDER BY dv.id
    LOOP
      v_linea_total := ROUND(v_det.total_linea, 2);
      v_linea_base := ROUND(v_linea_total / 1.18, 2);
      v_linea_igv := ROUND(v_linea_total - v_linea_base, 2);
      v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
        WHEN 'caja' THEN 'BX'
        WHEN 'cajas' THEN 'BX'
        WHEN 'paquete' THEN 'PK'
        WHEN 'paquetes' THEN 'PK'
        ELSE 'NIU'
      END;

      INSERT INTO public.notas_credito_detalles(
        nota_credito_id,
        detalle_venta_id,
        producto_id,
        almacen_id,
        codigo_producto,
        descripcion_original,
        tipo_unidad,
        unidad_sunat,
        cantidad_visual,
        piezas_reales,
        precio_unitario_comercial,
        subtotal,
        base_imponible,
        igv,
        tipo_venta_snapshot,
        pcs_snapshot,
        unidad_base_snapshot,
        repone_stock
      )
      VALUES (
        v_nota_id,
        v_det.id,
        v_det.producto_id,
        v_det.almacen_id,
        v_det.codigo,
        v_det.nombre,
        COALESCE(v_det.tipo_unidad, 'unidad'),
        v_unidad_sunat,
        v_det.cantidad,
        COALESCE(v_det.piezas_reales, v_det.cantidad),
        COALESCE(
          v_det.precio_unitario_comercial,
          CASE WHEN v_det.cantidad > 0
            THEN v_linea_total / v_det.cantidad
            ELSE 0
          END
        ),
        v_linea_total,
        v_linea_base,
        v_linea_igv,
        v_det.tipo_venta_snapshot,
        v_det.pcs_snapshot,
        v_det.unidad_base_snapshot,
        v_repone_stock
      )
      RETURNING id INTO v_last_detail_id;

      v_total := v_total + v_linea_total;
    END LOOP;

    IF v_last_detail_id IS NULL THEN
      RAISE EXCEPTION 'La venta no tiene detalles';
    END IF;

    -- Ajuste final por redondeo para igualar exactamente al comprobante original.
    v_diff := ROUND(COALESCE(v_comp.total, 0) - v_total, 2);
    IF ABS(v_diff) > 0 THEN
      UPDATE public.notas_credito_detalles
      SET
        subtotal = ROUND(subtotal + v_diff, 2),
        base_imponible = ROUND((subtotal + v_diff) / 1.18, 2),
        igv = ROUND(
          (subtotal + v_diff) - ((subtotal + v_diff) / 1.18),
          2
        ),
        precio_unitario_comercial = ROUND(
          (subtotal + v_diff) / GREATEST(cantidad_visual, 1),
          6
        )
      WHERE id = v_last_detail_id;
    END IF;

    v_total := ROUND(COALESCE(v_comp.total, 0), 2);

  -- ---------------------------------------------------------------------------
  -- 07: DEVOLUCIÓN PARCIAL POR ÍTEM
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '07' THEN
    IF jsonb_array_length(COALESCE(p_detalles, '[]'::jsonb)) = 0 THEN
      RAISE EXCEPTION 'Selecciona al menos un producto para devolver';
    END IF;

    FOR v_item IN
      SELECT value
      FROM jsonb_array_elements(p_detalles)
    LOOP
      v_cantidad := COALESCE(NULLIF(v_item->>'cantidad', '')::integer, 0);

      IF v_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a cero';
      END IF;

      SELECT
        dv.*,
        p.codigo,
        p.nombre,
        COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
      INTO v_det
      FROM public.detalle_ventas AS dv
      JOIN public.productos AS p ON p.id = dv.producto_id
      WHERE dv.id = NULLIF(v_item->>'detalle_venta_id', '')::bigint
        AND dv.venta_id = v_comp.venta_id
      FOR UPDATE OF dv;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Detalle de venta inválido';
      END IF;

      SELECT COALESCE(SUM(ncd.cantidad_visual), 0)::integer
      INTO v_reservado
      FROM public.notas_credito_detalles AS ncd
      JOIN public.notas_credito AS nc ON nc.id = ncd.nota_credito_id
      WHERE ncd.detalle_venta_id = v_det.id
        AND nc.afecta_stock = true
        AND nc.estado IN (
          'pendiente_envio',
          'procesando',
          'pendiente_reintento',
          'resultado_incierto',
          'aceptado'
        );

      IF v_cantidad > (v_det.cantidad - v_reservado) THEN
        RAISE EXCEPTION
          'La cantidad solicitada de % supera la disponible de % para %',
          v_cantidad,
          GREATEST(v_det.cantidad - v_reservado, 0),
          v_det.nombre;
      END IF;

      IF MOD(
        COALESCE(v_det.piezas_reales, v_det.cantidad) * v_cantidad,
        GREATEST(v_det.cantidad, 1)
      ) <> 0 THEN
        RAISE EXCEPTION
          'No se puede convertir exactamente la cantidad comercial de % a stock base',
          v_det.nombre;
      END IF;

      v_piezas := (
        COALESCE(v_det.piezas_reales, v_det.cantidad) * v_cantidad
      ) / GREATEST(v_det.cantidad, 1);

      v_linea_total := ROUND(
        (v_det.total_linea / GREATEST(v_det.cantidad, 1)) * v_cantidad,
        2
      );
      v_linea_base := ROUND(v_linea_total / 1.18, 2);
      v_linea_igv := ROUND(v_linea_total - v_linea_base, 2);
      v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
        WHEN 'caja' THEN 'BX'
        WHEN 'cajas' THEN 'BX'
        WHEN 'paquete' THEN 'PK'
        WHEN 'paquetes' THEN 'PK'
        ELSE 'NIU'
      END;

      INSERT INTO public.notas_credito_detalles(
        nota_credito_id,
        detalle_venta_id,
        producto_id,
        almacen_id,
        codigo_producto,
        descripcion_original,
        tipo_unidad,
        unidad_sunat,
        cantidad_visual,
        piezas_reales,
        precio_unitario_comercial,
        subtotal,
        base_imponible,
        igv,
        tipo_venta_snapshot,
        pcs_snapshot,
        unidad_base_snapshot,
        repone_stock
      )
      VALUES (
        v_nota_id,
        v_det.id,
        v_det.producto_id,
        v_det.almacen_id,
        v_det.codigo,
        v_det.nombre,
        COALESCE(v_det.tipo_unidad, 'unidad'),
        v_unidad_sunat,
        v_cantidad,
        v_piezas,
        ROUND(v_linea_total / v_cantidad, 6),
        v_linea_total,
        v_linea_base,
        v_linea_igv,
        v_det.tipo_venta_snapshot,
        v_det.pcs_snapshot,
        v_det.unidad_base_snapshot,
        v_repone_stock
      );

      v_total := v_total + v_linea_total;
    END LOOP;

    IF v_total <= 0 OR v_total > v_disponible + 0.02 THEN
      RAISE EXCEPTION
        'El total de la devolución S/ % supera el saldo tributario disponible S/ %',
        ROUND(v_total, 2),
        ROUND(v_disponible, 2);
    END IF;

  -- ---------------------------------------------------------------------------
  -- 04: DESCUENTO POSTERIOR / GLOBAL
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '04' THEN
    v_total := ROUND(COALESCE(p_monto_descuento, 0), 2);

    IF v_total <= 0 THEN
      RAISE EXCEPTION 'El monto del descuento debe ser mayor a cero';
    END IF;

    IF v_total > v_disponible + 0.02 THEN
      RAISE EXCEPTION
        'El descuento S/ % supera el saldo tributario disponible S/ %',
        v_total,
        v_disponible;
    END IF;

    v_linea_base := ROUND(v_total / 1.18, 2);
    v_linea_igv := ROUND(v_total - v_linea_base, 2);

    INSERT INTO public.notas_credito_detalles(
      nota_credito_id,
      descripcion_original,
      tipo_unidad,
      unidad_sunat,
      cantidad_visual,
      piezas_reales,
      precio_unitario_comercial,
      subtotal,
      base_imponible,
      igv,
      repone_stock
    )
    VALUES (
      v_nota_id,
      'DESCUENTO POSTERIOR',
      'servicio',
      'ZZ',
      1,
      0,
      v_total,
      v_total,
      v_linea_base,
      v_linea_igv,
      false
    );

  -- ---------------------------------------------------------------------------
  -- 03: CORRECCIÓN DE DESCRIPCIÓN
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '03' THEN
    IF jsonb_array_length(COALESCE(p_detalles, '[]'::jsonb)) <> 1 THEN
      RAISE EXCEPTION
        'Selecciona exactamente un producto para corregir su descripción';
    END IF;

    v_item := p_detalles->0;
    v_descripcion_corregida := NULLIF(
      TRIM(v_item->>'descripcion_corregida'),
      ''
    );

    IF v_descripcion_corregida IS NULL THEN
      RAISE EXCEPTION 'La descripción corregida es obligatoria';
    END IF;

    SELECT
      dv.*,
      p.codigo,
      p.nombre,
      COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
    INTO v_det
    FROM public.detalle_ventas AS dv
    JOIN public.productos AS p ON p.id = dv.producto_id
    WHERE dv.id = NULLIF(v_item->>'detalle_venta_id', '')::bigint
      AND dv.venta_id = v_comp.venta_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Detalle de venta inválido';
    END IF;

    v_total := ROUND(v_det.total_linea, 2);
    v_linea_base := ROUND(v_total / 1.18, 2);
    v_linea_igv := ROUND(v_total - v_linea_base, 2);
    v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
      WHEN 'caja' THEN 'BX'
      WHEN 'cajas' THEN 'BX'
      WHEN 'paquete' THEN 'PK'
      WHEN 'paquetes' THEN 'PK'
      ELSE 'NIU'
    END;

    INSERT INTO public.notas_credito_detalles(
      nota_credito_id,
      detalle_venta_id,
      producto_id,
      almacen_id,
      codigo_producto,
      descripcion_original,
      descripcion_corregida,
      tipo_unidad,
      unidad_sunat,
      cantidad_visual,
      piezas_reales,
      precio_unitario_comercial,
      subtotal,
      base_imponible,
      igv,
      tipo_venta_snapshot,
      pcs_snapshot,
      unidad_base_snapshot,
      repone_stock
    )
    VALUES (
      v_nota_id,
      v_det.id,
      v_det.producto_id,
      v_det.almacen_id,
      v_det.codigo,
      v_det.nombre,
      v_descripcion_corregida,
      COALESCE(v_det.tipo_unidad, 'unidad'),
      v_unidad_sunat,
      v_det.cantidad,
      0,
      COALESCE(
        v_det.precio_unitario_comercial,
        v_total / GREATEST(v_det.cantidad, 1)
      ),
      v_total,
      v_linea_base,
      v_linea_igv,
      v_det.tipo_venta_snapshot,
      v_det.pcs_snapshot,
      v_det.unidad_base_snapshot,
      false
    );
  END IF;

  SELECT
    ROUND(COALESCE(SUM(base_imponible), 0), 2),
    ROUND(COALESCE(SUM(igv), 0), 2),
    ROUND(COALESCE(SUM(subtotal), 0), 2)
  INTO v_base, v_igv, v_total
  FROM public.notas_credito_detalles
  WHERE nota_credito_id = v_nota_id;

  UPDATE public.notas_credito
  SET
    base_imponible = v_base,
    igv = v_igv,
    total = v_total
  WHERE id = v_nota_id;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'nota_credito_id', v_nota_id,
    'venta_id', v_comp.venta_id,
    'comprobante_id', p_comprobante_id,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'estado', 'pendiente_envio',
    'total', v_total,
    'reponer_stock', v_repone_stock
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.listar_documentos_electronicos_v1(p_fecha_inicio timestamp with time zone, p_fecha_fin_exclusiva timestamp with time zone, p_limite integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(categoria text, tipo_label text, id text, venta_id bigint, numero text, estado text, total numeric, tercero text, fecha_documento timestamp with time zone, descripcion_sunat text, pdf_path text, xml_path text, cdr_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 50), 10), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin', 'operador'
      )
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  IF p_fecha_inicio IS NULL OR p_fecha_fin_exclusiva IS NULL
     OR p_fecha_fin_exclusiva <= p_fecha_inicio THEN
    RAISE EXCEPTION 'Rango de fechas inválido';
  END IF;

  RETURN QUERY
  WITH documentos AS (
    SELECT
      CASE
        WHEN LOWER(COALESCE(ce.tipo_documento_sunat, '')) IN ('factura', '01')
          THEN 'factura'
        ELSE 'boleta'
      END::text AS categoria,
      CASE
        WHEN LOWER(COALESCE(ce.tipo_documento_sunat, '')) IN ('factura', '01')
          THEN 'Factura'
        ELSE 'Boleta'
      END::text AS tipo_label,
      ce.id::text AS id,
      ce.venta_id,
      (ce.serie || '-' || ce.correlativo)::text AS numero,
      ce.estado::text,
      ce.total::numeric AS total,
      COALESCE(NULLIF(ce.cliente_razon_social, ''), 'Cliente general')::text
        AS tercero,
      COALESCE(
        ce.fecha_emision_ts,
        ce.fecha_emision::timestamp AT TIME ZONE 'America/Lima',
        ce.created_at
      ) AS fecha_documento,
      ce.descripcion_sunat::text,
      ce.pdf_path::text,
      ce.xml_path::text,
      ce.cdr_path::text
    FROM public.comprobantes_electronicos ce

    UNION ALL

    SELECT
      'nota'::text,
      'Nota de crédito'::text,
      nc.id::text,
      nc.venta_id,
      (nc.serie || '-' || nc.correlativo)::text,
      nc.estado::text,
      nc.total::numeric,
      COALESCE(NULLIF(nc.motivo_descripcion, ''), 'Nota de crédito')::text,
      COALESCE(
        nc.fecha_emision_ts,
        nc.fecha_emision::timestamp AT TIME ZONE 'America/Lima',
        nc.created_at
      ),
      nc.descripcion_sunat::text,
      nc.pdf_path::text,
      nc.xml_path::text,
      nc.cdr_path::text
    FROM public.notas_credito nc

    UNION ALL

    SELECT
      'guia'::text,
      CASE
        WHEN g.tipo_guia = 'transportista' THEN 'GRE Transportista'
        ELSE 'GRE Remitente'
      END::text,
      g.id::text,
      g.venta_id,
      (g.serie || '-' || g.correlativo)::text,
      g.estado::text,
      NULL::numeric,
      COALESCE(NULLIF(g.destinatario_razon_social, ''), 'Destinatario')::text,
      COALESCE(g.fecha_emision, g.created_at),
      g.descripcion_sunat::text,
      g.pdf_path::text,
      g.xml_path::text,
      g.cdr_path::text
    FROM public.guias_remision g
  )
  SELECT
    d.categoria,
    d.tipo_label,
    d.id,
    d.venta_id,
    d.numero,
    d.estado,
    d.total,
    d.tercero,
    d.fecha_documento,
    d.descripcion_sunat,
    d.pdf_path,
    d.xml_path,
    d.cdr_path
  FROM documentos d
  WHERE d.fecha_documento >= p_fecha_inicio
    AND d.fecha_documento < p_fecha_fin_exclusiva
  ORDER BY d.fecha_documento DESC, d.id DESC
  LIMIT v_limite
  OFFSET v_offset;
END;
$function$;

CREATE OR REPLACE FUNCTION public.solicitar_baja_tributaria_v1(p_request_id uuid, p_tipo_origen text, p_origen_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_tipo_origen text := lower(trim(COALESCE(p_tipo_origen, '')));
  v_motivo text := upper(trim(COALESCE(p_motivo, '')));
  v_existing record;
  v_source record;
  v_solicitud_id uuid;
  v_tipo_proceso text;
  v_tipo_doc text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND lower(COALESCE(e.rol, '')) IN (
        'admin'
      )
  ) THEN
    RAISE EXCEPTION 'Solo un administrador activo puede solicitar una baja tributaria';
  END IF;

  IF p_request_id IS NULL OR p_origen_id IS NULL THEN
    RAISE EXCEPTION 'request_id y origen_id son obligatorios';
  END IF;

  IF v_tipo_origen NOT IN ('comprobante', 'nota_credito') THEN
    RAISE EXCEPTION 'Tipo de origen inválido';
  END IF;

  IF length(v_motivo) < 3 OR length(v_motivo) > 250 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 3 y 250 caracteres';
  END IF;

  SELECT * INTO v_existing
  FROM public.solicitudes_baja_tributaria
  WHERE request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'solicitud_id', v_existing.id,
      'estado', v_existing.estado,
      'tipo_proceso', v_existing.tipo_proceso
    );
  END IF;

  IF v_tipo_origen = 'comprobante' THEN
    SELECT
      ce.id,
      ce.venta_id,
      ce.tipo_documento_sunat,
      ce.serie,
      ce.correlativo,
      ce.fecha_emision,
      ce.moneda,
      ce.base_imponible,
      ce.igv,
      ce.total,
      ce.cliente_tipo_documento,
      ce.cliente_numero_documento,
      ce.estado,
      ce.estado_baja_tributaria
    INTO v_source
    FROM public.comprobantes_electronicos ce
    WHERE ce.id = p_origen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Comprobante electrónico no encontrado';
    END IF;

    IF v_source.estado <> 'aceptado' THEN
      RAISE EXCEPTION 'Solo puede darse de baja un comprobante aceptado por SUNAT';
    END IF;

    IF COALESCE(v_source.estado_baja_tributaria, 'ninguna') <> 'ninguna' THEN
      RAISE EXCEPTION 'El comprobante ya tiene una solicitud o proceso de baja';
    END IF;

    -- Una baja del documento original exige resolver primero las notas activas.
    IF EXISTS (
      SELECT 1
      FROM public.notas_credito nc
      WHERE nc.comprobante_id = p_origen_id
        AND nc.estado = 'aceptado'
        AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
    ) THEN
      RAISE EXCEPTION 'El comprobante tiene notas de crédito activas. Da de baja primero esas notas';
    END IF;

    v_tipo_doc := CASE lower(trim(COALESCE(v_source.tipo_documento_sunat, '')))
      WHEN 'factura' THEN '01'
      WHEN '01' THEN '01'
      WHEN 'boleta' THEN '03'
      WHEN '03' THEN '03'
      ELSE NULL
    END;

    IF v_tipo_doc IS NULL THEN
      RAISE EXCEPTION 'Tipo de comprobante no admitido para baja';
    END IF;

    v_tipo_proceso := CASE
      WHEN v_tipo_doc = '03' THEN 'resumen_boletas'
      ELSE 'comunicacion_baja'
    END;

    INSERT INTO public.solicitudes_baja_tributaria(
      request_id, tipo_origen, comprobante_id, venta_id,
      tipo_proceso, tipo_doc, serie, correlativo, fecha_documento,
      motivo, moneda, base_imponible, igv, total,
      cliente_tipo, cliente_numero, creado_por
    ) VALUES (
      p_request_id, 'comprobante', p_origen_id, v_source.venta_id,
      v_tipo_proceso, v_tipo_doc, v_source.serie, v_source.correlativo,
      v_source.fecha_emision, v_motivo, COALESCE(v_source.moneda, 'PEN'),
      COALESCE(v_source.base_imponible, 0), COALESCE(v_source.igv, 0),
      COALESCE(v_source.total, 0), v_source.cliente_tipo_documento,
      v_source.cliente_numero_documento, auth.uid()
    )
    RETURNING id INTO v_solicitud_id;

    UPDATE public.comprobantes_electronicos
    SET
      estado_baja_tributaria = 'solicitada',
      solicitud_baja_id = v_solicitud_id,
      baja_motivo = v_motivo
    WHERE id = p_origen_id;

  ELSE
    SELECT
      nc.id,
      nc.venta_id,
      nc.tipo_doc_afectado,
      nc.serie,
      nc.correlativo,
      nc.fecha_emision,
      nc.moneda,
      nc.base_imponible,
      nc.igv,
      nc.total,
      nc.cliente_tipo_documento,
      nc.cliente_numero_documento,
      nc.estado,
      nc.estado_baja_tributaria
    INTO v_source
    FROM public.notas_credito nc
    WHERE nc.id = p_origen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nota de crédito no encontrada';
    END IF;

    IF v_source.estado <> 'aceptado' THEN
      RAISE EXCEPTION 'Solo puede darse de baja una nota aceptada por SUNAT';
    END IF;

    IF COALESCE(v_source.estado_baja_tributaria, 'ninguna') <> 'ninguna' THEN
      RAISE EXCEPTION 'La nota ya tiene una solicitud o proceso de baja';
    END IF;

    v_tipo_doc := '07';
    v_tipo_proceso := CASE
      WHEN v_source.tipo_doc_afectado = '03'
        THEN 'resumen_boletas'
      ELSE 'comunicacion_baja'
    END;

    INSERT INTO public.solicitudes_baja_tributaria(
      request_id, tipo_origen, nota_credito_id, venta_id,
      tipo_proceso, tipo_doc, serie, correlativo, fecha_documento,
      motivo, moneda, base_imponible, igv, total,
      cliente_tipo, cliente_numero, creado_por
    ) VALUES (
      p_request_id, 'nota_credito', p_origen_id, v_source.venta_id,
      v_tipo_proceso, v_tipo_doc, v_source.serie, v_source.correlativo,
      v_source.fecha_emision, v_motivo, COALESCE(v_source.moneda, 'PEN'),
      COALESCE(v_source.base_imponible, 0), COALESCE(v_source.igv, 0),
      COALESCE(v_source.total, 0), v_source.cliente_tipo_documento,
      v_source.cliente_numero_documento, auth.uid()
    )
    RETURNING id INTO v_solicitud_id;

    UPDATE public.notas_credito
    SET
      estado_baja_tributaria = 'solicitada',
      solicitud_baja_id = v_solicitud_id,
      baja_motivo = v_motivo
    WHERE id = p_origen_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'solicitud_id', v_solicitud_id,
    'estado', 'pendiente',
    'tipo_proceso', v_tipo_proceso
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.tributario_preparar_procesos(p_tipo_proceso text DEFAULT NULL::text, p_usuario_id uuid DEFAULT NULL::uuid, p_sistema boolean DEFAULT false, p_limite_documentos integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_tipo_filtro text := NULLIF(lower(trim(COALESCE(p_tipo_proceso, ''))), '');
  v_grupo record;
  v_proceso_id uuid;
  v_correlativo integer;
  v_identificador text;
  v_prefijo text;
  v_ids jsonb := '[]'::jsonb;
  v_count integer;
BEGIN
  IF v_tipo_filtro IS NOT NULL
     AND v_tipo_filtro NOT IN ('resumen_boletas', 'comunicacion_baja') THEN
    RAISE EXCEPTION 'Tipo de proceso inválido';
  END IF;

  IF COALESCE(p_sistema, false) THEN
    RAISE EXCEPTION 'El procesamiento tributario automático está desactivado';
  END IF;

  IF p_usuario_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.empleados e
      WHERE e.auth_id = p_usuario_id
        AND COALESCE(e.activo, false) = true
        AND lower(COALESCE(e.rol, '')) IN (
          'admin'
        )
  ) THEN
    RAISE EXCEPTION 'Usuario no autorizado para preparar procesos tributarios';
  END IF;

  FOR v_grupo IN
    SELECT s.tipo_proceso, s.fecha_documento
    FROM public.solicitudes_baja_tributaria s
    WHERE s.estado = 'pendiente'
      AND s.proceso_id IS NULL
      AND (v_tipo_filtro IS NULL OR s.tipo_proceso = v_tipo_filtro)
    GROUP BY s.tipo_proceso, s.fecha_documento
    ORDER BY s.fecha_documento, s.tipo_proceso
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended(
        v_grupo.tipo_proceso || ':' || v_grupo.fecha_documento::text,
        0
      )
    );

    INSERT INTO public.correlativos_procesos_tributarios(
      tipo_proceso, fecha_referencia, ultimo_correlativo
    ) VALUES (
      v_grupo.tipo_proceso, v_grupo.fecha_documento, 1
    )
    ON CONFLICT (tipo_proceso, fecha_referencia)
    DO UPDATE SET
      ultimo_correlativo =
        public.correlativos_procesos_tributarios.ultimo_correlativo + 1,
      updated_at = now()
    RETURNING ultimo_correlativo INTO v_correlativo;

    v_prefijo := CASE
      WHEN v_grupo.tipo_proceso = 'resumen_boletas' THEN 'RC'
      ELSE 'RA'
    END;

    v_identificador :=
      v_prefijo || '-' ||
      to_char(v_grupo.fecha_documento, 'YYYYMMDD') || '-' ||
      lpad(v_correlativo::text, 3, '0');

    INSERT INTO public.procesos_tributarios(
      request_id, tipo_proceso, fecha_referencia, fecha_comunicacion,
      correlativo, identificador, creado_por
    ) VALUES (
      gen_random_uuid(), v_grupo.tipo_proceso, v_grupo.fecha_documento,
      (now() AT TIME ZONE 'America/Lima')::date,
      v_correlativo, v_identificador, p_usuario_id
    )
    RETURNING id INTO v_proceso_id;

    WITH seleccion AS (
      SELECT s.id
      FROM public.solicitudes_baja_tributaria s
      WHERE s.estado = 'pendiente'
        AND s.proceso_id IS NULL
        AND s.tipo_proceso = v_grupo.tipo_proceso
        AND s.fecha_documento = v_grupo.fecha_documento
      ORDER BY s.created_at, s.id
      LIMIT GREATEST(1, LEAST(COALESCE(p_limite_documentos, 500), 500))
      FOR UPDATE SKIP LOCKED
    ), insertados AS (
      INSERT INTO public.procesos_tributarios_detalles(
        proceso_id, solicitud_id, tipo_origen,
        comprobante_id, nota_credito_id, venta_id,
        tipo_doc, serie, correlativo, serie_numero,
        estado_resumen, motivo, moneda,
        cliente_tipo, cliente_numero,
        base_imponible, igv, total
      )
      SELECT
        v_proceso_id, s.id, s.tipo_origen,
        s.comprobante_id, s.nota_credito_id, s.venta_id,
        s.tipo_doc, s.serie, s.correlativo,
        s.serie || '-' || s.correlativo,
        '3', s.motivo, s.moneda,
        COALESCE(NULLIF(s.cliente_tipo, ''), '0'),
        COALESCE(NULLIF(s.cliente_numero, ''), '0'),
        s.base_imponible, s.igv, s.total
      FROM public.solicitudes_baja_tributaria s
      JOIN seleccion x ON x.id = s.id
      RETURNING solicitud_id
    )
    UPDATE public.solicitudes_baja_tributaria s
    SET
      estado = 'agrupada',
      proceso_id = v_proceso_id
    FROM insertados i
    WHERE s.id = i.solicitud_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 THEN
      DELETE FROM public.procesos_tributarios
      WHERE id = v_proceso_id;
    ELSE
      UPDATE public.comprobantes_electronicos ce
      SET estado_baja_tributaria = 'agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.proceso_id = v_proceso_id
        AND s.comprobante_id = ce.id;

      UPDATE public.notas_credito nc
      SET estado_baja_tributaria = 'agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.proceso_id = v_proceso_id
        AND s.nota_credito_id = nc.id;

      v_ids := v_ids || jsonb_build_array(v_proceso_id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'procesos_creados', jsonb_array_length(v_ids),
    'proceso_ids', v_ids
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.anular_venta_v2(p_venta_id bigint, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_detalle record;
  v_venta public.ventas%ROWTYPE;
  v_saldo integer;
  v_unidad_base text;
  v_actor_id bigint;
  v_actor_nombre text;
  v_actor_rol text;
  v_vendedor_nombre text;
  v_comprobantes_snapshot jsonb := '[]'::jsonb;
  v_facturacion_intentos_snapshot jsonb := '[]'::jsonb;
  v_constancias_snapshot jsonb := '[]'::jsonb;
  v_motivo text := TRIM(COALESCE(p_motivo, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  SELECT e.id, e.nombre, LOWER(COALESCE(e.rol, ''))
  INTO v_actor_id, v_actor_nombre, v_actor_rol
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rol no autorizado para anular ventas';
  END IF;

  IF LENGTH(v_motivo) < 3 THEN
    RAISE EXCEPTION 'El motivo de anulación debe tener al menos 3 caracteres';
  END IF;
  IF LENGTH(v_motivo) > 250 THEN
    RAISE EXCEPTION 'El motivo de anulación no puede superar 250 caracteres';
  END IF;

  SELECT * INTO v_venta
  FROM public.ventas
  WHERE id = p_venta_id
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1 FROM public.ventas_requests_anulados
      WHERE venta_id_original = p_venta_id
    ) THEN
      RETURN jsonb_build_object('success', true, 'idempotent', true);
    END IF;
    RAISE EXCEPTION 'La venta % no existe', p_venta_id;
  END IF;

  SELECT e.nombre INTO v_vendedor_nombre
  FROM public.empleados e
  WHERE e.id = v_venta.vendedor_id;

  IF EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
      AND LOWER(COALESCE(ce.estado, '')) IN (
        'pendiente',
        'pendiente_envio',
        'procesando',
        'pendiente_reintento',
        'ticket_pendiente',
        'resultado_incierto'
      )
  ) THEN
    RAISE EXCEPTION
      'No se puede anular la venta mientras el comprobante tenga un resultado tributario pendiente. Consulte primero su estado en SUNAT';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
      AND LOWER(COALESCE(ce.estado, '')) IN ('aceptado', 'accepted')
  ) THEN
    RAISE EXCEPTION 'La venta tiene un comprobante aceptado. Debe emitirse una nota de crédito';
  END IF;

  -- Conserva la evidencia del comprobante rechazado y de todos sus intentos
  -- antes de retirar las filas operativas. Así la anulación local no falla por
  -- la FK de facturacion_intentos y tampoco pierde la trazabilidad tributaria.
  SELECT COALESCE(
    jsonb_agg(to_jsonb(ce) ORDER BY ce.created_at, ce.id),
    '[]'::jsonb
  )
  INTO v_comprobantes_snapshot
  FROM public.comprobantes_electronicos ce
  WHERE ce.venta_id = p_venta_id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(fi) ORDER BY fi.created_at, fi.id),
    '[]'::jsonb
  )
  INTO v_facturacion_intentos_snapshot
  FROM public.facturacion_intentos fi
  JOIN public.comprobantes_electronicos ce
    ON ce.id = fi.comprobante_id
  WHERE ce.venta_id = p_venta_id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(cd) ORDER BY cd.id),
    '[]'::jsonb
  )
  INTO v_constancias_snapshot
  FROM public.constancias_descuento cd
  WHERE cd.venta_id = p_venta_id;

  IF v_venta.request_id IS NOT NULL THEN
    INSERT INTO public.ventas_requests_anulados(
      request_id,
      venta_id_original,
      anulada_por,
      vendedor_id_original,
      vendedor_nombre_snapshot,
      anulada_por_empleado_id,
      anulada_por_nombre_snapshot,
      motivo,
      anulada_at,
      venta_snapshot
    ) VALUES (
      v_venta.request_id,
      p_venta_id,
      auth.uid(),
      v_venta.vendedor_id,
      v_vendedor_nombre,
      v_actor_id,
      v_actor_nombre,
      v_motivo,
      clock_timestamp(),
      to_jsonb(v_venta) || jsonb_build_object(
        'comprobantes_electronicos', v_comprobantes_snapshot,
        'facturacion_intentos', v_facturacion_intentos_snapshot,
        'constancias_descuento', v_constancias_snapshot
      )
    )
    ON CONFLICT (request_id) DO UPDATE SET
      motivo = EXCLUDED.motivo,
      anulada_por = EXCLUDED.anulada_por,
      anulada_por_empleado_id = EXCLUDED.anulada_por_empleado_id,
      anulada_por_nombre_snapshot = EXCLUDED.anulada_por_nombre_snapshot,
      anulada_at = EXCLUDED.anulada_at;
  END IF;

  FOR v_detalle IN
    SELECT
      dv.producto_id,
      dv.almacen_id,
      COALESCE(
        NULLIF(dv.piezas_reales, 0),
        CASE
          WHEN LOWER(TRIM(COALESCE(dv.tipo_venta_snapshot, p.tipo_venta, ''))) IN ('paquetes','paquete','caja','solo_cajas')
            THEN dv.cantidad
          WHEN LOWER(TRIM(COALESCE(dv.tipo_venta_snapshot, p.tipo_venta, ''))) IN ('caja_paquetes','caja_unidades','ambos','caja_unidad','cajas_unidades')
           AND LOWER(TRIM(COALESCE(dv.tipo_unidad, 'unidad'))) IN ('caja','cajas','box','bx')
            THEN dv.cantidad * GREATEST(COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1), 1)
          ELSE dv.cantidad
        END
      ) AS piezas_reales,
      COALESCE(dv.precio_unitario, 0) AS precio_unitario,
      COALESCE(dv.tipo_venta_snapshot, UPPER(p.tipo_venta)) AS tipo_venta,
      COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1) AS pcs,
      COALESCE(
        dv.unidad_base_snapshot,
        CASE
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN ('PAQUETES','PAQUETE','CAJA_PAQUETES') THEN 'Paquete'
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN ('CAJA','SOLO_CAJAS') THEN 'Caja'
          ELSE 'Unidad'
        END
      ) AS unidad_base,
      p.nombre AS producto_nombre,
      COALESCE(pr.nombre, 'Generico') AS proveedor,
      a.nombre AS almacen_nombre
    FROM public.detalle_ventas dv
    JOIN public.productos p ON p.id = dv.producto_id
    LEFT JOIN public.proveedores pr ON pr.id = p.proveedor_id
    JOIN public.almacenes a ON a.id = dv.almacen_id
    WHERE dv.venta_id = p_venta_id
    ORDER BY dv.producto_id, dv.almacen_id
  LOOP
    IF v_detalle.piezas_reales <= 0 THEN
      RAISE EXCEPTION 'La venta contiene una línea sin cantidad base válida';
    END IF;

    PERFORM pg_advisory_xact_lock(v_detalle.producto_id);

    INSERT INTO public.inventario_almacen(producto_id, almacen_id, cantidad)
    VALUES(v_detalle.producto_id, v_detalle.almacen_id, v_detalle.piezas_reales)
    ON CONFLICT(producto_id, almacen_id)
    DO UPDATE SET cantidad = public.inventario_almacen.cantidad + EXCLUDED.cantidad
    RETURNING cantidad INTO v_saldo;

    v_unidad_base := v_detalle.unidad_base;

    INSERT INTO public.inventario_movimientos(
      fecha, producto_id, producto_nombre, pcs, proveedor,
      tipo, saldo, almacen_id, almacen_nombre, observaciones,
      ingreso_cant, ingreso_und, ingreso_p_unit,
      venta_id, venta_id_original, vendedor_id, vendedor_nombre_snapshot,
      anulado_por_id, anulado_por_nombre_snapshot, motivo_anulacion,
      tipo_venta_snapshot, unidad_base_snapshot, request_id
    ) VALUES (
      clock_timestamp(), v_detalle.producto_id, v_detalle.producto_nombre,
      v_detalle.pcs, v_detalle.proveedor,
      'ANULACION_VENTA', v_saldo, v_detalle.almacen_id,
      COALESCE(v_detalle.almacen_nombre, ''),
      'Anulación Venta #' || p_venta_id,
      v_detalle.piezas_reales, v_unidad_base, v_detalle.precio_unitario,
      p_venta_id, p_venta_id, v_venta.vendedor_id, v_vendedor_nombre,
      v_actor_id, v_actor_nombre, v_motivo,
      v_detalle.tipo_venta, v_unidad_base, v_venta.request_id
    );
  END LOOP;

  DELETE FROM public.facturacion_intentos
  WHERE comprobante_id IN (
    SELECT ce.id
    FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
  );
  DELETE FROM public.constancias_descuento WHERE venta_id = p_venta_id;
  DELETE FROM public.comprobantes_electronicos WHERE venta_id = p_venta_id;
  DELETE FROM public.pagos_venta WHERE venta_id = p_venta_id;
  DELETE FROM public.detalle_ventas WHERE venta_id = p_venta_id;
  DELETE FROM public.ventas WHERE id = p_venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'venta_id_original', p_venta_id,
    'vendedor', v_vendedor_nombre,
    'anulada_por', v_actor_nombre,
    'motivo', v_motivo
  );
END;
$function$;



-- Disponibilidad de nota: normaliza roles admin/operador.
CREATE OR REPLACE FUNCTION public.obtener_disponibilidad_nota_credito(p_comprobante_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_detalles jsonb;
  v_notas jsonb;
  v_total_comprometido numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  SELECT
    ce.*,
    v.total AS venta_total,
    v.fecha AS venta_fecha,
    v.estado_tributario,
    c.id AS cliente_id,
    c.nombre AS cliente_nombre,
    c.dni_ruc AS cliente_documento,
    c.tipo_doc AS cliente_tipo_doc,
    c.direccion AS cliente_direccion
  INTO v_comp
  FROM public.comprobantes_electronicos AS ce
  JOIN public.ventas AS v ON v.id = ce.venta_id
  LEFT JOIN public.clientes AS c ON c.id = v.cliente_id
  WHERE ce.id = p_comprobante_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  SELECT COALESCE(SUM(nc.total), 0)
  INTO v_total_comprometido
  FROM public.notas_credito AS nc
  WHERE nc.comprobante_id = p_comprobante_id
    AND nc.afecta_dinero = true
    AND nc.estado IN (
      'pendiente_envio',
      'procesando',
      'pendiente_reintento',
      'resultado_incierto',
      'aceptado'
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'detalle_venta_id', dv.id,
        'producto_id', dv.producto_id,
        'almacen_id', dv.almacen_id,
        'codigo', p.codigo,
        'nombre', p.nombre,
        'cantidad_original', dv.cantidad,
        'cantidad_comprometida', COALESCE(r.cantidad, 0),
        'cantidad_disponible', GREATEST(
          dv.cantidad - COALESCE(r.cantidad, 0),
          0
        ),
        'piezas_reales', COALESCE(dv.piezas_reales, dv.cantidad),
        'tipo_unidad', COALESCE(dv.tipo_unidad, 'unidad'),
        'precio_unitario_comercial', COALESCE(
          dv.precio_unitario_comercial,
          CASE
            WHEN dv.cantidad > 0 THEN
              COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) / dv.cantidad
            ELSE 0
          END
        ),
        'subtotal', COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal),
        'tipo_venta_snapshot', dv.tipo_venta_snapshot,
        'pcs_snapshot', dv.pcs_snapshot,
        'unidad_base_snapshot', dv.unidad_base_snapshot
      )
      ORDER BY dv.id
    ),
    '[]'::jsonb
  )
  INTO v_detalles
  FROM public.detalle_ventas AS dv
  JOIN public.productos AS p ON p.id = dv.producto_id
  LEFT JOIN LATERAL (
    SELECT SUM(ncd.cantidad_visual)::integer AS cantidad
    FROM public.notas_credito_detalles AS ncd
    JOIN public.notas_credito AS nc
      ON nc.id = ncd.nota_credito_id
    WHERE ncd.detalle_venta_id = dv.id
      AND nc.afecta_stock = true
      AND nc.estado IN (
        'pendiente_envio',
        'procesando',
        'pendiente_reintento',
        'resultado_incierto',
        'aceptado'
      )
  ) AS r ON true
  WHERE dv.venta_id = v_comp.venta_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', nc.id,
        'serie', nc.serie,
        'correlativo', nc.correlativo,
        'motivo_codigo', nc.motivo_codigo,
        'motivo_descripcion', nc.motivo_descripcion,
        'estado', nc.estado,
        'total', nc.total,
        'codigo_sunat', nc.codigo_sunat,
        'descripcion_sunat', nc.descripcion_sunat,
        'aceptado_at', nc.aceptado_at
      )
      ORDER BY nc.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_notas
  FROM public.notas_credito AS nc
  WHERE nc.comprobante_id = p_comprobante_id;

  RETURN jsonb_build_object(
    'comprobante', jsonb_build_object(
      'id', v_comp.id,
      'venta_id', v_comp.venta_id,
      'tipo_documento_sunat', v_comp.tipo_documento_sunat,
      'serie', v_comp.serie,
      'correlativo', v_comp.correlativo,
      'estado', v_comp.estado,
      'total', v_comp.total,
      'cliente_nombre', COALESCE(
        v_comp.cliente_razon_social,
        v_comp.cliente_nombre,
        'Cliente General'
      ),
      'cliente_documento', COALESCE(
        v_comp.cliente_numero_documento,
        v_comp.cliente_documento,
        ''
      )
    ),
    'detalles', v_detalles,
    'notas', v_notas,
    'total_comprometido', ROUND(v_total_comprometido, 2),
    'total_disponible', GREATEST(
      ROUND(COALESCE(v_comp.total, 0) - v_total_comprometido, 2),
      0
    )
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 10. PERMISOS: SIN ESCRITURA TRIBUTARIA DIRECTA DESDE FLUTTER
-- -----------------------------------------------------------------------------
REVOKE ALL ON TABLE public.comprobantes_electronicos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.comprobantes_electronicos FROM authenticated;
GRANT SELECT ON TABLE public.comprobantes_electronicos TO authenticated;

REVOKE ALL ON TABLE public.facturacion_intentos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.facturacion_intentos FROM authenticated;
GRANT SELECT ON TABLE public.facturacion_intentos TO authenticated;

REVOKE ALL ON TABLE public.notas_credito FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.notas_credito FROM authenticated;
GRANT SELECT ON TABLE public.notas_credito TO authenticated;

REVOKE ALL ON TABLE public.notas_credito_detalles FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.notas_credito_detalles FROM authenticated;
GRANT SELECT ON TABLE public.notas_credito_detalles TO authenticated;

REVOKE ALL ON TABLE public.notas_credito_intentos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.notas_credito_intentos FROM authenticated;
GRANT SELECT ON TABLE public.notas_credito_intentos TO authenticated;

REVOKE ALL ON TABLE public.guias_remision FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.guias_remision FROM authenticated;
GRANT SELECT ON TABLE public.guias_remision TO authenticated;

REVOKE ALL ON TABLE public.guias_remision_detalles FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.guias_remision_detalles FROM authenticated;
GRANT SELECT ON TABLE public.guias_remision_detalles TO authenticated;

REVOKE ALL ON TABLE public.guias_remision_intentos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.guias_remision_intentos FROM authenticated;
GRANT SELECT ON TABLE public.guias_remision_intentos TO authenticated;

REVOKE ALL ON TABLE public.solicitudes_baja_tributaria FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.solicitudes_baja_tributaria FROM authenticated;
GRANT SELECT ON TABLE public.solicitudes_baja_tributaria TO authenticated;

REVOKE ALL ON TABLE public.procesos_tributarios FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.procesos_tributarios FROM authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios TO authenticated;

REVOKE ALL ON TABLE public.procesos_tributarios_detalles FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.procesos_tributarios_detalles FROM authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios_detalles TO authenticated;

REVOKE ALL ON TABLE public.procesos_tributarios_intentos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.procesos_tributarios_intentos FROM authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios_intentos TO authenticated;

REVOKE ALL ON TABLE public.constancias_descuento FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.constancias_descuento FROM authenticated;
GRANT SELECT ON TABLE public.constancias_descuento TO authenticated;

REVOKE ALL ON TABLE public.correlativos_procesos_tributarios FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.series_comprobantes FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.series_comprobantes FROM authenticated;

-- Los datos del cliente nunca deben exponerse a anon.
REVOKE ALL ON TABLE public.clientes FROM PUBLIC, anon;

REVOKE ALL ON TABLE public.documentos_tributarios_reconciliaciones FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.documentos_tributarios_reconciliaciones FROM authenticated;
GRANT SELECT ON TABLE public.documentos_tributarios_reconciliaciones TO authenticated;

-- Catálogos operativos GRE: admin y operador mediante RLS.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.gre_conductores,
  public.gre_vehiculos,
  public.gre_transportistas,
  public.gre_transportistas_agencias
TO authenticated;
REVOKE ALL ON TABLE
  public.gre_conductores,
  public.gre_vehiculos,
  public.gre_transportistas,
  public.gre_transportistas_agencias
FROM PUBLIC, anon;

-- -----------------------------------------------------------------------------
-- 11. EXECUTE: RPC PÚBLICAS MÍNIMAS E INTERNAS SOLO SERVICE_ROLE
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)
  TO service_role;

REVOKE ALL ON FUNCTION public.facturacion_finalizar_comprobante(uuid,uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.facturacion_finalizar_comprobante(uuid,uuid,text,jsonb)
  TO service_role;

REVOKE ALL ON FUNCTION public.nota_credito_claim(uuid,uuid,text,boolean,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nota_credito_claim(uuid,uuid,text,boolean,boolean)
  TO service_role;

REVOKE ALL ON FUNCTION public.nota_credito_finalizar(uuid,uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nota_credito_finalizar(uuid,uuid,text,jsonb)
  TO service_role;

REVOKE ALL ON FUNCTION public.gre_claim(uuid,text,boolean)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.gre_claim_v2(uuid,uuid,text,boolean,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gre_claim_v2(uuid,uuid,text,boolean,boolean)
  TO service_role;

REVOKE ALL ON FUNCTION public.gre_finalizar(uuid,uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gre_finalizar(uuid,uuid,text,jsonb)
  TO service_role;

REVOKE ALL ON FUNCTION public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)
  TO service_role;

REVOKE ALL ON FUNCTION public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)
  TO service_role;

REVOKE ALL ON FUNCTION public.tributario_preparar_procesos(text,uuid,boolean,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tributario_preparar_procesos(text,uuid,boolean,integer)
  TO service_role;

REVOKE ALL ON FUNCTION public.resolver_resultado_incierto_v1(text,uuid,text,text,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolver_resultado_incierto_v1(text,uuid,text,text,text,uuid)
  TO service_role;

-- RPC invocables desde Flutter; todas vuelven a verificar auth/rol internamente.
REVOKE ALL ON FUNCTION public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)
  TO authenticated;

REVOKE ALL ON FUNCTION public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  TO authenticated;

REVOKE ALL ON FUNCTION public.guardar_guia_remision_v3(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_guia_remision_v3(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.obtener_disponibilidad_nota_credito(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_disponibilidad_nota_credito(uuid)
  TO authenticated;

REVOKE ALL ON FUNCTION public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer)
  TO authenticated;

REVOKE ALL ON FUNCTION public.actualizar_configuracion_negocio_v1(jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_configuracion_negocio_v1(jsonb)
  TO authenticated;

REVOKE ALL ON FUNCTION public.anular_venta_v2(bigint,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.anular_venta_v2(bigint,text)
  TO authenticated;

-- Evita saltarse anular_venta_v2 mediante la función antigua.
REVOKE ALL ON FUNCTION public.anular_venta(bigint,jsonb)
  FROM PUBLIC, anon, authenticated;

COMMIT;
