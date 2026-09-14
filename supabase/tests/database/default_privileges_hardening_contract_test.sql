BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(4);

CREATE TABLE public._stomni_acl_probe_20260907000007 (
  id bigint
);

CREATE SEQUENCE public._stomni_acl_probe_seq_20260907000007;

CREATE FUNCTION public._stomni_acl_probe_fn_20260907000007()
RETURNS integer
LANGUAGE sql
AS $function$
  SELECT 1;
$function$;

SELECT table_privs_are(
  'public',
  '_stomni_acl_probe_20260907000007',
  'anon',
  ARRAY[]::text[],
  'tablas futuras no otorgan privilegios automaticos a anon'
);

SELECT table_privs_are(
  'public',
  '_stomni_acl_probe_20260907000007',
  'authenticated',
  ARRAY[]::text[],
  'tablas futuras no otorgan privilegios automaticos a authenticated'
);

SELECT ok(
  NOT has_sequence_privilege(
    'anon',
    'public._stomni_acl_probe_seq_20260907000007',
    'USAGE'
  )
  AND NOT has_sequence_privilege(
    'anon',
    'public._stomni_acl_probe_seq_20260907000007',
    'SELECT'
  )
  AND NOT has_sequence_privilege(
    'anon',
    'public._stomni_acl_probe_seq_20260907000007',
    'UPDATE'
  )
  AND NOT has_sequence_privilege(
    'authenticated',
    'public._stomni_acl_probe_seq_20260907000007',
    'USAGE'
  )
  AND NOT has_sequence_privilege(
    'authenticated',
    'public._stomni_acl_probe_seq_20260907000007',
    'SELECT'
  )
  AND NOT has_sequence_privilege(
    'authenticated',
    'public._stomni_acl_probe_seq_20260907000007',
    'UPDATE'
  ),
  'secuencias futuras no se exponen automaticamente a clientes'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public._stomni_acl_probe_fn_20260907000007()',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public._stomni_acl_probe_fn_20260907000007()',
    'EXECUTE'
  ),
  'funciones futuras requieren GRANT EXECUTE explicito'
);

SELECT * FROM finish();

ROLLBACK;
