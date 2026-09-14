-- Compatibilidad temporal para el backfill fiscal F3.7.
-- PostgreSQL 17 no expone min(uuid); se crea sólo durante la migración siguiente
-- y se elimina inmediatamente después para no ampliar el esquema final.
BEGIN;

CREATE OR REPLACE FUNCTION private._uuid_min_compat(p_state uuid, p_value uuid)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_state::text <= p_value::text THEN p_state
    ELSE p_value
  END
$$;

REVOKE ALL ON FUNCTION private._uuid_min_compat(uuid,uuid)
  FROM PUBLIC, anon, authenticated;

DROP AGGREGATE IF EXISTS public.min(uuid);
CREATE AGGREGATE public.min(uuid) (
  SFUNC = private._uuid_min_compat,
  STYPE = uuid,
  COMBINEFUNC = private._uuid_min_compat,
  PARALLEL = SAFE
);

COMMENT ON AGGREGATE public.min(uuid) IS
  'Compatibilidad temporal para F3.7; se elimina en la migración inmediatamente posterior.';

COMMIT;
