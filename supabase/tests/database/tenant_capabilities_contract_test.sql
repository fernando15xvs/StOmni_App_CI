BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_capabilities'::regclass AND attname='inventory_enabled' AND attnotnull AND NOT attisdropped),'inventory_enabled existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_capabilities'::regclass AND attname='multiple_branches' AND attnotnull AND NOT attisdropped),'multiple_branches existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_capabilities'::regclass AND attname='multiple_warehouses' AND attnotnull AND NOT attisdropped),'multiple_warehouses existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_capabilities'::regclass AND conname='business_capabilities_inventory_dependencies'),'constraint dependencias inventario existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='current_business_capability' AND lower(pg_get_functiondef(p.oid)) LIKE '%where b.organization_id=v_org%'),'helper capability filtra tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_business_profile_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%multiple_branches%' AND lower(pg_get_functiondef(p.oid)) LIKE '%multiple_warehouses%'),'perfil expone capacidades nuevas');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_business_capabilities_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%cannot disable multiple branches%' AND lower(pg_get_functiondef(p.oid)) LIKE '%cannot disable multiple warehouses%'),'RPC protege estructura activa');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_business_capabilities_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%cannot disable inventory while stock exists%'),'RPC protege stock existente');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.branches'::regclass AND tgname='zz_branches_capability_guard' AND NOT tgisinternal),'branch capability trigger activo');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.almacenes'::regclass AND tgname='zz_almacenes_capability_guard' AND NOT tgisinternal),'warehouse capability trigger activo');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventario_almacen'::regclass AND tgname='zz_inventario_almacen_capability_guard' AND NOT tgisinternal),'inventory balance capability trigger activo');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='enforce_inventory_balance_capability' AND lower(pg_get_functiondef(p.oid)) LIKE '%tg_op=''delete''%return old%'),'DELETE del trigger no se cancela');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='require_inventory_capability'),'helper require inventory existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='enforce_branch_capability' AND lower(pg_get_functiondef(p.oid)) LIKE '%multiple_branches%'),'branch enforcement usa capability');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='enforce_warehouse_capability' AND lower(pg_get_functiondef(p.oid)) LIKE '%multiple_warehouses%'),'warehouse enforcement usa capability');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_business_capabilities_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%expiry tracking requires lot tracking%'),'expiry requiere lotes');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='update_business_capabilities_v1' AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org%'),'update capabilities tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='business_capabilities'),'business_capabilities sigue indexada');

SELECT * FROM finish();
ROLLBACK;
