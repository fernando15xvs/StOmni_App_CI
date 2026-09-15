-- GRE: número opcional de bultos / unidades físicas de manipulación.
--
-- No representa cajas comerciales ni piezas del detalle. Se persiste a nivel
-- de la guía y, cuando existe, la Edge Function lo envía como envio.numBultos.

ALTER TABLE public.guias_remision
  ADD COLUMN IF NOT EXISTS cantidad_bultos integer;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'guias_remision_cantidad_bultos_check'
      AND conrelid = 'public.guias_remision'::regclass
  ) THEN
    ALTER TABLE public.guias_remision
      ADD CONSTRAINT guias_remision_cantidad_bultos_check
      CHECK (cantidad_bultos IS NULL OR cantidad_bultos > 0);
  END IF;
END
$$;

COMMENT ON COLUMN public.guias_remision.cantidad_bultos IS
  'Número total opcional de bultos o unidades físicas de manipulación del traslado.';

CREATE OR REPLACE FUNCTION public.guardar_guia_remision_v4(
  p_guia_id uuid DEFAULT NULL,
  p_request_id uuid DEFAULT NULL,
  p_emitir boolean DEFAULT false,
  p_tipo_guia text DEFAULT 'remitente',
  p_origen_tipo text DEFAULT 'manual',
  p_venta_id bigint DEFAULT NULL,
  p_transferencia_id bigint DEFAULT NULL,
  p_guia_remitente_id uuid DEFAULT NULL,
  p_documento_relacionado_tipo text DEFAULT NULL,
  p_documento_relacionado_numero text DEFAULT NULL,
  p_motivo_codigo text DEFAULT '01',
  p_motivo_descripcion text DEFAULT 'VENTA',
  p_modalidad_transporte text DEFAULT '02',
  p_fecha_emision timestamptz DEFAULT now(),
  p_fecha_traslado timestamptz DEFAULT now(),
  p_destinatario jsonb DEFAULT '{}'::jsonb,
  p_remitente jsonb DEFAULT '{}'::jsonb,
  p_partida jsonb DEFAULT '{}'::jsonb,
  p_llegada jsonb DEFAULT '{}'::jsonb,
  p_transportista_id bigint DEFAULT NULL,
  p_conductor_id bigint DEFAULT NULL,
  p_vehiculo_id bigint DEFAULT NULL,
  p_peso_total numeric DEFAULT NULL,
  p_cantidad_bultos integer DEFAULT NULL,
  p_peso_editado boolean DEFAULT false,
  p_observacion text DEFAULT NULL,
  p_detalles jsonb DEFAULT '[]'::jsonb,
  p_ind_transbordo boolean DEFAULT false,
  p_transportista_transbordo_id bigint DEFAULT NULL,
  p_agencia_origen_id bigint DEFAULT NULL,
  p_agencia_destino_id bigint DEFAULT NULL,
  p_destino_entrega_tipo text DEFAULT 'direccion_cliente'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_result jsonb;
  v_guia_id uuid;
BEGIN
  IF p_cantidad_bultos IS NOT NULL AND p_cantidad_bultos <= 0 THEN
    RAISE EXCEPTION 'El número de bultos debe ser mayor a cero.';
  END IF;

  v_result := public.guardar_guia_remision_v3(
    p_guia_id => p_guia_id,
    p_request_id => p_request_id,
    p_emitir => p_emitir,
    p_tipo_guia => p_tipo_guia,
    p_origen_tipo => p_origen_tipo,
    p_venta_id => p_venta_id,
    p_transferencia_id => p_transferencia_id,
    p_guia_remitente_id => p_guia_remitente_id,
    p_documento_relacionado_tipo => p_documento_relacionado_tipo,
    p_documento_relacionado_numero => p_documento_relacionado_numero,
    p_motivo_codigo => p_motivo_codigo,
    p_motivo_descripcion => p_motivo_descripcion,
    p_modalidad_transporte => p_modalidad_transporte,
    p_fecha_emision => p_fecha_emision,
    p_fecha_traslado => p_fecha_traslado,
    p_destinatario => p_destinatario,
    p_remitente => p_remitente,
    p_partida => p_partida,
    p_llegada => p_llegada,
    p_transportista_id => p_transportista_id,
    p_conductor_id => p_conductor_id,
    p_vehiculo_id => p_vehiculo_id,
    p_peso_total => p_peso_total,
    p_peso_editado => p_peso_editado,
    p_observacion => p_observacion,
    p_detalles => p_detalles,
    p_ind_transbordo => p_ind_transbordo,
    p_transportista_transbordo_id => p_transportista_transbordo_id,
    p_agencia_origen_id => p_agencia_origen_id,
    p_agencia_destino_id => p_agencia_destino_id,
    p_destino_entrega_tipo => p_destino_entrega_tipo
  );

  v_guia_id := NULLIF(v_result->>'guia_id', '')::uuid;
  IF v_guia_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la guía guardada.';
  END IF;

  UPDATE public.guias_remision
  SET cantidad_bultos = p_cantidad_bultos,
      updated_at = now()
  WHERE id = v_guia_id;

  RETURN v_result || jsonb_build_object(
    'cantidad_bultos', p_cantidad_bultos
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.guardar_guia_remision_v4(
  uuid, uuid, boolean, text, text, bigint, bigint, uuid, text, text, text,
  text, text, timestamptz, timestamptz, jsonb, jsonb, jsonb, jsonb, bigint,
  bigint, bigint, numeric, integer, boolean, text, jsonb, boolean, bigint,
  bigint, bigint, text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.guardar_guia_remision_v4(
  uuid, uuid, boolean, text, text, bigint, bigint, uuid, text, text, text,
  text, text, timestamptz, timestamptz, jsonb, jsonb, jsonb, jsonb, bigint,
  bigint, bigint, numeric, integer, boolean, text, jsonb, boolean, bigint,
  bigint, bigint, text
) TO authenticated, service_role;
