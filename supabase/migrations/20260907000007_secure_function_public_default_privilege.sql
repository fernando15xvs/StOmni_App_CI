-- PostgreSQL grants EXECUTE on newly created functions to PUBLIC by its
-- built-in global default. A schema-scoped REVOKE cannot override that
-- global default, so this must be changed at the role level.
BEGIN;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMIT;
