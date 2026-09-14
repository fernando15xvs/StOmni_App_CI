-- Limpieza inmediata de la compatibilidad temporal usada por F3.7.
BEGIN;

DROP AGGREGATE IF EXISTS public.min(uuid);
DROP FUNCTION IF EXISTS private._uuid_min_compat(uuid,uuid);

COMMIT;
