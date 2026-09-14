begin;

create extension if not exists pgtap with schema extensions;

select plan(10);

select ok(
  to_regprocedure('public.get_current_business_configuration_v1()') is not null,
  'get_current_business_configuration_v1 existe'
);

select ok(
  to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)') is not null,
  'actualizar_configuracion_negocio_v1 existe'
);

select ok(
  coalesce((
    select p.prosecdef
    from pg_proc p
    where p.oid = to_regprocedure(
      'public.actualizar_configuracion_negocio_v1(jsonb)'
    )
  ), false),
  'actualizar_configuracion_negocio_v1 es SECURITY DEFINER'
);

select ok(
  position(
    'set search_path to ''''' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) > 0,
  'actualizar_configuracion_negocio_v1 fija search_path vacío'
);

select ok(
  has_function_privilege(
    'authenticated',
    to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)'),
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)'),
    'EXECUTE'
  ),
  'solo authenticated puede invocar la RPC de empresa'
);

select ok(
  position(
    'private.require_current_organization_id()' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) > 0
  and position(
    'private.has_permission(''tenant.admin'')' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) > 0,
  'la RPC deriva tenant y exige administrador en backend'
);

select ok(
  position(
    'organization_id = v_organization_id' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) > 0
  and position(
    'where id = 1' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) = 0,
  'la escritura selecciona configuración por tenant y no por singleton'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.configuracion_negocio',
    'UPDATE'
  ),
  'authenticated no puede saltarse el allowlist escribiendo la tabla directamente'
);

select ok(
  position(
    'precios_incluyen_igv' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) = 0
  and position(
    'porcentaje_igv' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) = 0,
  'la pantalla de empresa no puede mutar reglas de IGV'
);

select ok(
  position(
    'ambiente' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) = 0
  and position(
    'token' in lower(
      pg_get_functiondef(
        to_regprocedure('public.actualizar_configuracion_negocio_v1(jsonb)')
      )
    )
  ) = 0,
  'la RPC de empresa no expone ambiente ni tokens tributarios'
);

select * from finish();
rollback;
