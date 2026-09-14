begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

select ok(
  not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'Permitir todo en clientes'
  ),
  'clientes ya no conserva la policy global permisiva'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'clientes_tenant_select'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and lower(coalesce(qual,'')) like '%tenant.read%'
      and lower(coalesce(qual,'')) like '%row_belongs_to_current_organization%'
  ),
  'clientes SELECT exige membership/permiso y tenant actual'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'clientes_tenant_insert'
      and cmd = 'INSERT'
      and roles = array['authenticated']::name[]
      and lower(coalesce(with_check,'')) like '%tenant.write%'
      and lower(coalesce(with_check,'')) like '%row_belongs_to_current_organization%'
  ),
  'clientes INSERT exige escritura dentro del tenant actual'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'clientes_tenant_update'
      and cmd = 'UPDATE'
      and roles = array['authenticated']::name[]
      and lower(coalesce(qual,'')) like '%tenant.write%'
      and lower(coalesce(with_check,'')) like '%tenant.write%'
      and lower(coalesce(qual,'')) like '%row_belongs_to_current_organization%'
      and lower(coalesce(with_check,'')) like '%row_belongs_to_current_organization%'
  ),
  'clientes UPDATE valida USING y WITH CHECK tenant-aware'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'clientes_tenant_delete'
      and cmd = 'DELETE'
      and roles = array['authenticated']::name[]
      and lower(coalesce(qual,'')) like '%tenant.write%'
      and lower(coalesce(qual,'')) like '%row_belongs_to_current_organization%'
  ),
  'clientes DELETE exige escritura dentro del tenant actual'
);

select ok(
  not has_table_privilege('anon', 'public.clientes', 'SELECT')
  and not has_table_privilege('anon', 'public.clientes', 'INSERT')
  and not has_table_privilege('anon', 'public.clientes', 'UPDATE')
  and not has_table_privilege('anon', 'public.clientes', 'DELETE'),
  'anon no tiene CRUD sobre clientes'
);

select ok(
  has_table_privilege('authenticated', 'public.clientes', 'SELECT')
  and has_table_privilege('authenticated', 'public.clientes', 'INSERT')
  and has_table_privilege('authenticated', 'public.clientes', 'UPDATE')
  and has_table_privilege('authenticated', 'public.clientes', 'DELETE'),
  'authenticated conserva solo el CRUD requerido por Flutter en clientes'
);

select ok(
  not has_table_privilege('authenticated', 'public.clientes', 'TRUNCATE')
  and not has_table_privilege('authenticated', 'public.clientes', 'TRIGGER')
  and not has_table_privilege('authenticated', 'public.clientes', 'REFERENCES'),
  'clientes no expone privilegios de tabla innecesarios a authenticated'
);

select ok(
  has_sequence_privilege('authenticated', 'public.clientes_id_seq', 'USAGE'),
  'authenticated conserva USAGE de la secuencia de clientes para INSERT'
);

select ok(
  not has_sequence_privilege('anon', 'public.clientes_id_seq', 'USAGE'),
  'anon no usa la secuencia de clientes'
);

select ok(
  not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'transferencias_stock'
      and policyname = 'Permitir todo en transferencias_stock'
  ),
  'transferencias_stock ya no conserva la policy global permisiva'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'transferencias_stock'
      and policyname = 'transferencias_stock_tenant_select'
      and cmd = 'SELECT'
      and roles = array['authenticated']::name[]
      and lower(coalesce(qual,'')) like '%tenant.read%'
      and lower(coalesce(qual,'')) like '%row_belongs_to_current_organization%'
  ),
  'transferencias_stock permite sólo lectura tenant-aware'
);

select ok(
  not has_table_privilege('anon', 'public.transferencias_stock', 'SELECT')
  and not has_table_privilege('anon', 'public.transferencias_stock', 'INSERT')
  and not has_table_privilege('anon', 'public.transferencias_stock', 'UPDATE')
  and not has_table_privilege('anon', 'public.transferencias_stock', 'DELETE'),
  'anon no tiene acceso CRUD a transferencias_stock'
);

select ok(
  has_table_privilege('authenticated', 'public.transferencias_stock', 'SELECT'),
  'authenticated conserva lectura de transferencias_stock para GRE'
);

select ok(
  not has_table_privilege('authenticated', 'public.transferencias_stock', 'INSERT')
  and not has_table_privilege('authenticated', 'public.transferencias_stock', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.transferencias_stock', 'DELETE')
  and not has_table_privilege('authenticated', 'public.transferencias_stock', 'TRUNCATE'),
  'authenticated no puede mutar directamente transferencias_stock'
);

select ok(
  not has_sequence_privilege('anon', 'public.transferencias_stock_id_seq', 'USAGE')
  and not has_sequence_privilege('authenticated', 'public.transferencias_stock_id_seq', 'USAGE'),
  'la secuencia de transferencias no esta expuesta a clientes'
);

select ok(
  not has_table_privilege('anon', 'public.inventario_operaciones_idempotentes', 'SELECT')
  and not has_table_privilege('anon', 'public.inventario_operaciones_idempotentes', 'INSERT')
  and not has_table_privilege('anon', 'public.inventario_operaciones_idempotentes', 'UPDATE')
  and not has_table_privilege('anon', 'public.inventario_operaciones_idempotentes', 'DELETE'),
  'anon no accede a inventario_operaciones_idempotentes'
);

select ok(
  not has_table_privilege('authenticated', 'public.inventario_operaciones_idempotentes', 'SELECT')
  and not has_table_privilege('authenticated', 'public.inventario_operaciones_idempotentes', 'INSERT')
  and not has_table_privilege('authenticated', 'public.inventario_operaciones_idempotentes', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.inventario_operaciones_idempotentes', 'DELETE'),
  'authenticated no accede directamente a inventario_operaciones_idempotentes'
);

select ok(
  not has_table_privilege('anon', 'public.sys_processed_requests', 'SELECT')
  and not has_table_privilege('anon', 'public.sys_processed_requests', 'INSERT')
  and not has_table_privilege('anon', 'public.sys_processed_requests', 'UPDATE')
  and not has_table_privilege('anon', 'public.sys_processed_requests', 'DELETE'),
  'anon no accede a sys_processed_requests'
);

select ok(
  not has_table_privilege('authenticated', 'public.sys_processed_requests', 'SELECT')
  and not has_table_privilege('authenticated', 'public.sys_processed_requests', 'INSERT')
  and not has_table_privilege('authenticated', 'public.sys_processed_requests', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.sys_processed_requests', 'DELETE'),
  'authenticated no accede directamente a sys_processed_requests'
);

select * from finish();
rollback;
