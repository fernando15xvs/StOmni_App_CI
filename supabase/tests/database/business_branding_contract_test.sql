begin;

create extension if not exists pgtap with schema extensions;

select plan(12);

select has_column(
  'public', 'configuracion_negocio', 'organization_id',
  'branding conserva organization_id en la fuente autoritativa'
);

select has_column(
  'public', 'configuracion_negocio', 'nombre_comercial',
  'branding reutiliza nombre_comercial'
);

select has_column(
  'public', 'configuracion_negocio', 'logo_url',
  'branding reutiliza logo_url'
);

select ok(
  to_regprocedure('public.get_current_business_configuration_v1()') is not null,
  'existe la lectura tenant-aware de configuración'
);

select ok(
  coalesce((
    select p.prosecdef
    from pg_proc p
    where p.oid = to_regprocedure(
      'public.get_current_business_configuration_v1()'
    )
  ), false),
  'la lectura de branding es SECURITY DEFINER'
);

select ok(
  position(
    'set search_path to ''''' in lower(
      pg_get_functiondef(
        to_regprocedure('public.get_current_business_configuration_v1()')
      )
    )
  ) > 0,
  'la lectura de branding fija search_path vacío'
);

select ok(
  position(
    'private.require_current_organization_id()' in lower(
      pg_get_functiondef(
        to_regprocedure('public.get_current_business_configuration_v1()')
      )
    )
  ) > 0,
  'el tenant de branding se deriva server-side'
);

select ok(
  position(
    'private.has_permission(''tenant.read'')' in lower(
      pg_get_functiondef(
        to_regprocedure('public.get_current_business_configuration_v1()')
      )
    )
  ) > 0,
  'leer branding exige tenant.read'
);

select ok(
  position(
    'where c.organization_id = v_organization_id' in lower(
      pg_get_functiondef(
        to_regprocedure('public.get_current_business_configuration_v1()')
      )
    )
  ) > 0,
  'la configuración se filtra por el tenant autenticado'
);

select ok(
  position(
    'to_jsonb(c)' in lower(
      pg_get_functiondef(
        to_regprocedure('public.get_current_business_configuration_v1()')
      )
    )
  ) > 0,
  'la RPC devuelve los campos autoritativos de nombre y logo'
);

select ok(
  has_function_privilege(
    'authenticated',
    to_regprocedure('public.get_current_business_configuration_v1()'),
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    to_regprocedure('public.get_current_business_configuration_v1()'),
    'EXECUTE'
  ),
  'branding sólo se expone al cliente autenticado'
);

select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'logos_tenant_admin_insert'
      and with_check ilike '%current_organization_id()%'
  ),
  'la escritura de logos mantiene prefijo tenant server-side'
);

select * from finish();
rollback;
