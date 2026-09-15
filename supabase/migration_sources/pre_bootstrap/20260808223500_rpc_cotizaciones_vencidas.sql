CREATE OR REPLACE FUNCTION public.actualizar_cotizaciones_vencidas()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.cotizaciones
  SET estado = 'vencida'
  WHERE estado = 'pendiente'
    AND (fecha + (COALESCE(validez_dias, 15) || ' days')::interval) < now();
END;
$$;
