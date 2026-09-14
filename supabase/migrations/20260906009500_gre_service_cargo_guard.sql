-- Un servicio puede facturarse, pero nunca representar mercancía física en GRE.
BEGIN;

CREATE OR REPLACE FUNCTION public._gre_reject_service_cargo_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF EXISTS(
    SELECT 1 FROM public.productos p
    WHERE p.id=NEW.producto_id AND coalesce(p.es_servicio,false)
  ) THEN
    RAISE EXCEPTION 'Los servicios no pueden formar parte de una Guía de Remisión'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER gre_detail_reject_services
BEFORE INSERT OR UPDATE OF producto_id ON public.guias_remision_detalles
FOR EACH ROW EXECUTE FUNCTION public._gre_reject_service_cargo_v1();

REVOKE ALL ON FUNCTION public._gre_reject_service_cargo_v1()
  FROM PUBLIC,anon,authenticated;

COMMIT;
