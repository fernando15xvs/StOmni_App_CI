CREATE OR REPLACE FUNCTION public.obtener_tendencia_movimientos(
    p_tipo TEXT, 
    p_inicio TIMESTAMP WITH TIME ZONE, 
    p_fin TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    fecha_agrupada DATE,
    total NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        DATE(fecha AT TIME ZONE 'America/Lima') AS fecha_agrupada,
        SUM(monto) AS total
    FROM public.movimientos
    WHERE tipo = p_tipo
      AND fecha >= p_inicio
      AND fecha <= p_fin
    GROUP BY DATE(fecha AT TIME ZONE 'America/Lima')
    ORDER BY fecha_agrupada ASC;
END;
$$;
