-- F3.2 contract repair: the shared customer gateway persists an optional phone
-- value, but the canonical clientes table did not expose that column.
BEGIN;

ALTER TABLE public.clientes
  ADD COLUMN IF NOT EXISTS telefono text;

COMMENT ON COLUMN public.clientes.telefono IS
  'Teléfono opcional del cliente, aislado por las policies RLS de clientes.';

COMMIT;
