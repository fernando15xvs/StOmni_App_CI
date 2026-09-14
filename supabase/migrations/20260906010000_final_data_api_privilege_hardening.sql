-- Final additive hardening for current production drift detected by the local
-- schema laboratory. This migration is intentionally idempotent and only
-- removes table/sequence privileges that the Data API does not need.
BEGIN;

-- Remove inherited PUBLIC grants first so effective privileges cannot bypass
-- the explicit role grants below.
REVOKE ALL ON TABLE public.clientes, public.transferencias_stock FROM PUBLIC, anon, authenticated;

-- Flutter still needs CRUD on clientes, but never DDL-like table privileges.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.clientes TO authenticated;

-- Transfer mutations must go through hardened RPCs; GRE only needs reads.
GRANT SELECT ON TABLE public.transferencias_stock TO authenticated;

REVOKE ALL ON SEQUENCE public.transferencias_stock_id_seq FROM PUBLIC, anon, authenticated;

COMMIT;
