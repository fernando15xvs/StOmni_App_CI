CREATE OR REPLACE FUNCTION public.obtener_tendencia_movimientos(
  p_tipo text,
  p_inicio timestamp with time zone,
  p_fin timestamp with time zone
)
RETURNS TABLE(fecha_agrupada date, total numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  RETURN QUERY
  SELECT
    DATE(m.fecha AT TIME ZONE 'America/Lima') AS fecha_agrupada,
    SUM(m.monto) AS total
  FROM public.movimientos AS m
  WHERE m.tipo = p_tipo
    AND m.fecha >= p_inicio
    AND m.fecha <= p_fin
  GROUP BY DATE(m.fecha AT TIME ZONE 'America/Lima')
  ORDER BY fecha_agrupada ASC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.obtener_tendencia_movimientos(
  text,
  timestamp with time zone,
  timestamp with time zone
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.obtener_tendencia_movimientos(
  text,
  timestamp with time zone,
  timestamp with time zone
) TO authenticated, service_role;
