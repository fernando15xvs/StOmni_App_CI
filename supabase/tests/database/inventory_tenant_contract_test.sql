BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(26);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'almacenes','inventario_almacen','inventario_movimientos',
      'inventario_operaciones_idempotentes','inventory_lots','inventory_serials',
      'inventory_traceability_consumptions','inventory_traceability_receipts',
      'stock_alert_tx_context','transferencias_stock','sys_processed_requests'
    ]::text[]) AS t(table_name)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid=format('public.%I',t.table_name)::regclass
        AND a.attname='organization_id'
        AND a.attnotnull
        AND NOT a.attisdropped
    )
  ),
  'todas las tablas de inventario tienen organization_id NOT NULL'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.almacenes'::regclass
      AND conname='almacenes_organization_id_id_key'
      AND contype='u'
  ),
  'almacenes expone clave compuesta tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_movimientos'::regclass
      AND conname='inventario_movimientos_organization_id_id_key'
      AND contype='u'
  ),
  'kardex expone clave compuesta tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_almacen'::regclass
      AND conname='inventario_almacen_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_almacen'::regclass
      AND conname='inventario_almacen_organization_warehouse_fkey'
      AND confrelid='public.almacenes'::regclass
  ),
  'saldo referencia producto y almacén del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_movimientos'::regclass
      AND conname='inventario_movimientos_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_movimientos'::regclass
      AND conname='inventario_movimientos_organization_warehouse_fkey'
      AND confrelid='public.almacenes'::regclass
  ),
  'kardex referencia producto y almacén del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventario_operaciones_idempotentes'::regclass
      AND conname='inventario_operaciones_idempotentes_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'idempotencia de inventario referencia producto tenant-qualified'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_lots'::regclass
      AND conname='inventory_lots_organization_product_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_lots'::regclass
      AND conname='inventory_lots_organization_warehouse_fkey'
  ),
  'lotes quedan tenant-qualified por producto y almacén'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_serials'::regclass
      AND conname='inventory_serials_organization_product_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_serials'::regclass
      AND conname='inventory_serials_organization_warehouse_fkey'
  ),
  'series quedan tenant-qualified por producto y almacén'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_traceability_consumptions'::regclass
      AND conname='inventory_traceability_consumptions_organization_product_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_traceability_consumptions'::regclass
      AND conname='inventory_traceability_consumptions_organization_warehouse_fkey'
  ),
  'consumos de trazabilidad quedan tenant-qualified'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_traceability_receipts'::regclass
      AND conname='inventory_traceability_receipts_organization_product_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.inventory_traceability_receipts'::regclass
      AND conname='inventory_traceability_receipts_organization_warehouse_fkey'
  ),
  'recepciones de trazabilidad quedan tenant-qualified'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.transferencias_stock'::regclass
      AND conname='transferencias_stock_organization_product_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.transferencias_stock'::regclass
      AND conname='transferencias_stock_organization_origin_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.transferencias_stock'::regclass
      AND conname='transferencias_stock_organization_destination_fkey'
  ),
  'traslado referencia producto, origen y destino del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.transferencias_stock'::regclass
      AND conname='transferencias_stock_organization_exit_movement_fkey'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.transferencias_stock'::regclass
      AND conname='transferencias_stock_organization_entry_movement_fkey'
  ),
  'traslado referencia movimientos del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.sys_processed_requests'::regclass
      AND conname='sys_processed_requests_organization_product_fkey'
  ),
  'idempotencia de alta de producto queda tenant-qualified'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'almacenes','inventario_almacen','inventario_movimientos',
      'inventario_operaciones_idempotentes','inventory_lots','inventory_serials',
      'inventory_traceability_consumptions','inventory_traceability_receipts',
      'stock_alert_tx_context','transferencias_stock','sys_processed_requests'
    ]::text[]) AS t(table_name)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid=format('public.%I',t.table_name)::regclass
        AND tgname=t.table_name||'_enforce_organization_id'
        AND NOT tgisinternal
    )
  ),
  'todas las tablas de inventario tienen trigger tenant'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'almacenes','inventario_almacen','inventario_movimientos',
      'inventario_operaciones_idempotentes','inventory_lots','inventory_serials',
      'inventory_traceability_consumptions','inventory_traceability_receipts',
      'stock_alert_tx_context','transferencias_stock','sys_processed_requests'
    ]::text[]) AS t(table_name)
    JOIN pg_class c ON c.oid=format('public.%I',t.table_name)::regclass
    WHERE NOT c.relrowsecurity
  ),
  'RLS está habilitado en todas las tablas de inventario'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='almacenes'
      AND policyname='almacenes_tenant_select'
      AND lower(qual) LIKE '%tenant.read%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'almacenes SELECT está aislado por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='almacenes'
      AND policyname='almacenes_tenant_update'
      AND lower(qual) LIKE '%tenant.admin%'
      AND lower(with_check) LIKE '%tenant.admin%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
      AND lower(with_check) LIKE '%row_belongs_to_current_organization%'
  ),
  'almacenes UPDATE usa USING + WITH CHECK tenant-aware'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='inventario_almacen'
      AND policyname='inventario_almacen_tenant_select'
      AND lower(qual) LIKE '%tenant.read%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'saldo de inventario SELECT está aislado por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='inventario_movimientos'
      AND policyname='inventario_movimientos_tenant_select'
      AND lower(qual) LIKE '%tenant.admin%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'kardex conserva lectura admin y añade tenant predicate'
);

SELECT ok(
  NOT has_table_privilege('authenticated','public.inventario_operaciones_idempotentes','SELECT')
  AND NOT has_table_privilege('authenticated','public.inventory_traceability_consumptions','SELECT')
  AND NOT has_table_privilege('authenticated','public.inventory_traceability_receipts','SELECT')
  AND NOT has_table_privilege('authenticated','public.sys_processed_requests','SELECT'),
  'tablas internas de idempotencia/trazabilidad no se exponen al cliente'
);

SELECT ok(
  NOT has_function_privilege('authenticated','private.enforce_inventory_organization_id()','EXECUTE')
  AND NOT has_function_privilege('authenticated','private.assert_warehouse_in_current_organization(bigint)','EXECUTE')
  AND NOT has_function_privilege('authenticated','private.assert_supplier_in_current_organization(bigint,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','private.assert_inventory_request_scope(uuid)','EXECUTE'),
  'helpers privados de inventario no son invocables por authenticated'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='list_inventory_lots_v1'
      AND NOT p.prosecdef
      AND position('organization_id = private.require_current_organization_id()' IN pg_get_functiondef(p.oid))>0
  )
  AND EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='list_inventory_serials_v1'
      AND NOT p.prosecdef
      AND position('organization_id = private.require_current_organization_id()' IN pg_get_functiondef(p.oid))>0
  ),
  'listados de lotes/series son SECURITY INVOKER y filtran tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='registrar_ingreso_mercaderia_scaled_v2'
      AND position('assert_product_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('assert_warehouse_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('assert_supplier_in_current_organization' IN pg_get_functiondef(p.oid))>0
  ),
  'ingreso de mercadería valida producto/proveedor/almacenes tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='registrar_merma_scaled_v4'
      AND position('assert_inventory_request_scope' IN pg_get_functiondef(p.oid))>0
      AND position('assert_product_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('assert_warehouse_in_current_organization' IN pg_get_functiondef(p.oid))>0
  )
  AND EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='trasladar_stock_scaled_v4'
      AND position('assert_inventory_request_scope' IN pg_get_functiondef(p.oid))>0
      AND position('assert_product_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('assert_warehouse_in_current_organization' IN pg_get_functiondef(p.oid))>0
  ),
  'merma y traslado validan request/producto/almacenes tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='crear_producto_con_stock'
      AND position('organization_id=v_organization_id' IN replace(pg_get_functiondef(p.oid),' ',''))>0
      AND position('assert_warehouse_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('assert_supplier_in_current_organization' IN pg_get_functiondef(p.oid))>0
  ),
  'alta producto+stock tiene idempotencia y padres limitados al tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='actualizar_producto_seguro_v1'
      AND position('assert_product_in_current_organization' IN pg_get_functiondef(p.oid))>0
      AND position('p.organization_id=v_organization_id' IN replace(pg_get_functiondef(p.oid),' ',''))>0
      AND position('m.organization_id=v_organization_id' IN replace(pg_get_functiondef(p.oid),' ',''))>0
  ),
  'edición de producto y apertura quedan limitadas al tenant'
);

SELECT * FROM finish();
ROLLBACK;
