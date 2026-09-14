BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(19);

SELECT ok(
  to_regprocedure('private.assert_inventory_request_scope(uuid)') IS NOT NULL
  AND position(
    'organization_id IS DISTINCT FROM'
    IN pg_get_functiondef('private.assert_inventory_request_scope(uuid)'::regprocedure)
  )=0
  AND position(
    'require_current_organization_id'
    IN pg_get_functiondef('private.assert_inventory_request_scope(uuid)'::regprocedure)
  )>0,
  'inventario valida membership/request sin reservar UUIDs de otros tenants'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'inventario_operaciones_idempotentes',
      'sys_processed_requests',
      'transferencias_stock'
    ]::text[]) AS t(table_name)
    CROSS JOIN LATERAL (
      SELECT c.oid AS relid,
             (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='request_id' AND NOT attisdropped) AS request_attnum
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=t.table_name
    ) x
    WHERE EXISTS (
      SELECT 1 FROM pg_constraint pc
      WHERE pc.conrelid=x.relid
        AND pc.contype IN ('p','u')
        AND pc.conkey=ARRAY[x.request_attnum]::smallint[]
    )
    OR EXISTS (
      SELECT 1
      FROM pg_index i
      WHERE i.indrelid=x.relid
        AND i.indisunique
        AND i.indisvalid
        AND i.indisready
        AND i.indnkeyatts=1
        AND pg_get_indexdef(i.indexrelid,1,true)='request_id'
    )
  ),
  'tablas idempotentes directas no conservan constraint ni índice UNIQUE request_id-only'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'inventario_operaciones_idempotentes',
      'sys_processed_requests',
      'transferencias_stock'
    ]::text[]) AS t(table_name)
    CROSS JOIN LATERAL (
      SELECT c.oid AS relid,
             (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='organization_id' AND NOT attisdropped) AS org_attnum,
             (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='request_id' AND NOT attisdropped) AS request_attnum
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=t.table_name
    ) x
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_constraint pc
      WHERE pc.conrelid=x.relid
        AND pc.contype IN ('p','u')
        AND pc.conkey=ARRAY[x.org_attnum,x.request_attnum]::smallint[]
    )
  ),
  'tablas idempotentes directas tienen clave única (organization_id,request_id)'
);

SELECT ok(
  to_regprocedure('private.inventory_tenant_request_key_v1(uuid,uuid)') IS NOT NULL
  AND NOT has_function_privilege(
    'authenticated','private.inventory_tenant_request_key_v1(uuid,uuid)','EXECUTE'
  ),
  'namespace interno de recepción trazable existe y no es invocable por cliente'
);

SELECT ok(
  position(
    'inventory_tenant_request_key_v1'
    IN pg_get_functiondef(
      'public.register_traceable_merchandise_receipt_v1(uuid,bigint,bigint,numeric,timestamp with time zone,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb)'::regprocedure
    )
  )>0
  AND position(
    'organization_id=v_organization_id'
    IN regexp_replace(
      pg_get_functiondef(
        'public.register_traceable_merchandise_receipt_v1(uuid,bigint,bigint,numeric,timestamp with time zone,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb)'::regprocedure
      ),'\s+','','g'
    )
  )>0,
  'recepción trazable conserva retry legacy propio y namespacea requests nuevos por tenant'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated','private.assert_inventory_request_scope(uuid)','EXECUTE'
  ),
  'guard de request de inventario sigue siendo privado'
);

SELECT ok(
  position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef(
      'public.registrar_ingreso_mercaderia_v2(uuid,bigint,timestamp with time zone,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)'::regprocedure
    )
  )>0
  AND position(
    'v_organization_id::text||'':''||p_request_id::text'
    IN regexp_replace(
      pg_get_functiondef(
        'public.registrar_ingreso_mercaderia_v2(uuid,bigint,timestamp with time zone,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)'::regprocedure
      ),'\s+','','g'
    )
  )>0,
  'ingreso serializa retries por tenant+request_id'
);

SELECT ok(
  position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef(
      'public.registrar_merma_v2(uuid,bigint,bigint,integer,text,timestamp with time zone)'::regprocedure
    )
  )>0
  AND position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef(
      'public.trasladar_stock_v2(uuid,bigint,bigint,bigint,integer,text,timestamp with time zone)'::regprocedure
    )
  )>0,
  'merma y traslado conservan exclusión transaccional de retries'
);

SELECT ok(
  position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef('public.crear_producto_con_stock(uuid,jsonb,jsonb)'::regprocedure)
  )>0
  AND position(
    'organization_id=v_organization_idANDrequest_id=p_request_id'
    IN regexp_replace(
      pg_get_functiondef('public.crear_producto_con_stock(uuid,jsonb,jsonb)'::regprocedure),
      '\s+','','g'
    )
  )>0,
  'alta producto+stock serializa y consulta idempotencia dentro del tenant'
);

SELECT ok(
  position(
    'FOR UPDATE'
    IN upper(pg_get_functiondef(
      'public._consume_inventory_traceability_v1(uuid,bigint,bigint,numeric,jsonb)'::regprocedure
    ))
  )>0,
  'consumo trazable bloquea filas de stock antes de descontar'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'clientes','productos','almacenes','inventario_almacen','inventario_movimientos',
      'ventas','purchase_orders','purchase_receipts','gastos'
    ]::text[]) AS t(table_name)
    CROSS JOIN LATERAL (
      SELECT c.oid AS relid,
             (SELECT attnum FROM pg_attribute WHERE attrelid=c.oid AND attname='organization_id' AND NOT attisdropped) AS org_attnum
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=t.table_name
    ) x
    WHERE x.org_attnum IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM pg_index i
         WHERE i.indrelid=x.relid
           AND i.indisvalid
           AND i.indisready
           AND i.indnatts>=1
           AND pg_get_indexdef(i.indexrelid,1,true)='organization_id'
       )
  ),
  'tablas críticas tienen al menos un índice tenant-leading'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='inventario_operaciones_idempotentes'
      AND indexdef LIKE '%(organization_id, request_id)%'
  )
  AND EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='sys_processed_requests'
      AND indexdef LIKE '%(organization_id, request_id)%'
  ),
  'lookups idempotentes principales tienen índice organization_id/request_id'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='inventory_traceability_receipts'
      AND indexdef LIKE '%(organization_id, request_id)%'
  )
  AND EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='inventory_traceability_consumptions'
      AND indexdef LIKE '%(organization_id, request_id%'
  ),
  'trazabilidad tiene caminos tenant-leading para request_id'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='purchase_orders'
      AND indexdef LIKE '%(organization_id, request_id)%'
      AND indexdef LIKE 'CREATE UNIQUE INDEX%'
  )
  AND EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='purchase_receipts'
      AND indexdef LIKE '%(organization_id, request_id)%'
      AND indexdef LIKE 'CREATE UNIQUE INDEX%'
  ),
  'compras conserva idempotencia tenant-local como referencia de concurrencia'
);

SELECT ok(
  position(
    'organization_id=v_organization_idANDrequest_id=p_request_id'
    IN regexp_replace(
      pg_get_functiondef('public.crear_producto_con_stock(uuid,jsonb,jsonb)'::regprocedure),
      '\s+','','g'
    )
  )>0
  AND position(
    'io.organization_id=v_organization_idANDio.request_id=p_request_id'
    IN regexp_replace(
      pg_get_functiondef(
        'public.registrar_ingreso_mercaderia_v2(uuid,bigint,timestamp with time zone,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)'::regprocedure
      ),'\s+','','g'
    )
  )>0,
  'retry lookup no depende de UUID global en catálogo/inventario'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='transferencias_stock'
      AND indexdef LIKE '%(organization_id, request_id)%'
  ),
  'traslados tienen acceso tenant-leading por request_id'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid='public.correlativos_procesos_tributarios'::regclass
      AND c.contype='p'
      AND pg_get_constraintdef(c.oid)='PRIMARY KEY (organization_id, tipo_proceso, fecha_referencia)'
  ),
  'correlativos tributarios tienen namespace primario por tenant/tipo/fecha'
);

SELECT ok(
  position(
    'pg_advisory_xact_lock(hashtextextended(v_org::text||'':''||v_grupo.tipo_proceso||'':''||v_grupo.fecha_documento::text,0))'
    IN regexp_replace(
      pg_get_functiondef('public.tributario_preparar_procesos(text,uuid,boolean,integer)'::regprocedure),
      '\s+','','g'
    )
  )>0
  AND position(
    'ONCONFLICT(ORGANIZATION_ID,TIPO_PROCESO,FECHA_REFERENCIA)'
    IN upper(regexp_replace(
      pg_get_functiondef('public.tributario_preparar_procesos(text,uuid,boolean,integer)'::regprocedure),
      '\s+','','g'
    ))
  )>0
  AND position(
    'FORUPDATESKIPLOCKED'
    IN upper(regexp_replace(
      pg_get_functiondef('public.tributario_preparar_procesos(text,uuid,boolean,integer)'::regprocedure),
      '\s+','','g'
    ))
  )>0,
  'preparación tributaria serializa correlativo por tenant y distribuye trabajo con SKIP LOCKED'
);

SELECT ok(
  position(
    'FROMpublic.series_comprobantesASscWHEREsc.organization_id=private.require_current_organization_id()ANDsc.tipo_documento_sunat=v_tipo_comprobanteANDsc.activo=trueFORUPDATE;'
    IN regexp_replace(
      pg_get_functiondef(
        'public.process_sale_v3(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure
      ),'\s+','','g'
    )
  )>0
  AND position(
    'UPDATEpublic.series_comprobantesSETultimo_correlativo=ultimo_correlativo+1WHEREorganization_id=private.require_current_organization_id()ANDid=v_serie_id'
    IN regexp_replace(
      pg_get_functiondef(
        'public.process_sale_v3(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure
      ),'\s+','','g'
    )
  )>0,
  'correlativo de comprobante se bloquea y actualiza dentro del tenant'
);

SELECT * FROM finish();
ROLLBACK;
