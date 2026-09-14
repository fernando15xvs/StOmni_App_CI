-- Fase 3.7 SaaS: una organización nueva no debe anunciar facturación
-- electrónica antes de tener configuración/series fiscales propias.
-- No modifica filas existentes; sólo cambia el default para futuras capacidades.
BEGIN;

ALTER TABLE public.business_capabilities
  ALTER COLUMN electronic_invoicing SET DEFAULT false;

COMMENT ON COLUMN public.business_capabilities.electronic_invoicing IS
  'Facturación electrónica del tenant. Nuevas organizaciones inician en false y la habilitan después de configurar su superficie fiscal.';

COMMIT;
