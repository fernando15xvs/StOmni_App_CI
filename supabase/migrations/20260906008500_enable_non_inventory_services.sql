-- El flujo de servicios ya existe en backend + móvil + desktop. Activarlo no
-- cambia ningún producto existente; sólo habilita el catálogo inicialmente vacío.
BEGIN;

UPDATE public.business_capabilities
SET services=true,
    revision=revision+1,
    updated_at=now()
WHERE business_id=1 AND services=false;

COMMIT;
