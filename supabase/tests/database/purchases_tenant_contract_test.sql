BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(38);

SELECT ok(
  (SELECT bool_and(attnotnull)
   FROM pg_attribute
   WHERE attrelid IN (
     'public.purchase_orders'::regclass,
     'public.purchase_order_lines'::regclass,
     'public.purchase_receipts'::regclass,
     'public.purchase_receipt_lines'::regclass,
     'public.gastos'::regclass,
     'public.pagos_gasto'::regclass
   )
     AND attname='organization_id'
     AND NOT attisdropped),
  'tablas de compras/gastos tienen organization_id NOT NULL'
);

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_orders_organization_id_id_key' AND contype='u'),'purchase_orders expone clave tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_order_lines_organization_id_id_key' AND contype='u'),'purchase_order_lines expone clave tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipts_organization_id_id_key' AND contype='u'),'purchase_receipts expone clave tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipt_lines_organization_id_id_key' AND contype='u'),'purchase_receipt_lines expone clave tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='gastos_organization_id_id_key' AND contype='u'),'gastos expone clave tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='pagos_gasto_organization_id_id_key' AND contype='u'),'pagos_gasto expone clave tenant');

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_orders_supplier_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, supplier_id)%REFERENCES proveedores(organization_id, id)%'),'OC/proveedor tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_orders_warehouse_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, warehouse_id)%REFERENCES almacenes(organization_id, id)%'),'OC/almacén tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_order_lines_purchase_order_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, purchase_order_id)%REFERENCES purchase_orders(organization_id, id)%'),'línea/OC tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_order_lines_product_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, product_id)%REFERENCES productos(organization_id, id)%'),'línea/producto tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipts_purchase_order_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, purchase_order_id)%REFERENCES purchase_orders(organization_id, id)%'),'recepción/OC tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipt_lines_purchase_receipt_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, purchase_receipt_id)%REFERENCES purchase_receipts(organization_id, id)%'),'línea/recepción tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipt_lines_purchase_order_line_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, purchase_order_line_id)%REFERENCES purchase_order_lines(organization_id, id)%'),'línea recepción/línea OC tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='gastos_proveedor_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, proveedor_id)%REFERENCES proveedores(organization_id, id)%'),'gasto/proveedor tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='pagos_gasto_gasto_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, gasto_id)%REFERENCES gastos(organization_id, id)%'),'pago/gasto tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='pagos_gasto_request_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, request_id)%REFERENCES pagos_deuda_requests(organization_id, request_id)%'),'pago/request deuda tenant-qualified');

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_orders_organization_request_key' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'idempotencia OC por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='purchase_receipts_organization_request_key' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'idempotencia recepción por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='pagos_gasto' AND indexname='pagos_gasto_organization_request_uidx' AND indexdef ILIKE '%organization_id%request_id%'),'idempotencia pago gasto por tenant');

SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='gastos' AND policyname='gastos_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'gastos SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='pagos_gasto' AND policyname='pagos_gasto_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'pagos_gasto SELECT tenant-aware');
SELECT ok(
  NOT has_table_privilege('authenticated','public.purchase_orders','SELECT')
  AND NOT has_table_privilege('authenticated','public.purchase_order_lines','SELECT')
  AND NOT has_table_privilege('authenticated','public.purchase_receipts','SELECT')
  AND NOT has_table_privilege('authenticated','public.purchase_receipt_lines','SELECT'),
  'tablas de OC/recepción son RPC-only'
);
SELECT ok(
  has_table_privilege('authenticated','public.gastos','SELECT')
  AND NOT has_table_privilege('authenticated','public.gastos','INSERT')
  AND NOT has_table_privilege('authenticated','public.gastos','UPDATE')
  AND NOT has_table_privilege('authenticated','public.gastos','DELETE'),
  'gastos tiene lectura directa pero mutación sólo RPC'
);

SELECT ok(
  pg_get_functiondef('public._business_enforce_purchase_capability()'::regprocedure)
    ILIKE '%business_capabilities%organization_id = v_org%'
  AND pg_get_functiondef('public._business_enforce_purchase_capability()'::regprocedure)
    NOT ILIKE '%business_id = 1%',
  'guard de capability de compras es tenant-aware y no singleton'
);
SELECT ok(
  pg_get_functiondef('public._service_block_purchase_line_v1()'::regprocedure)
    ILIKE '%p.organization_id=v_org%',
  'guard de servicios en compra scopea producto por tenant'
);
SELECT ok(
  pg_get_functiondef('private.purchase_order_json(bigint)'::regprocedure)
    ILIKE '%o.organization_id=private.require_current_organization_id()%'
  AND NOT has_function_privilege('authenticated','private.purchase_order_json(bigint)','EXECUTE'),
  'serializer privado de OC sólo devuelve tenant actual'
);

SELECT ok(
  pg_get_functiondef('public.create_purchase_order_v1(uuid,bigint,bigint,timestamptz,timestamptz,text,jsonb)'::regprocedure)
    ILIKE '%private.assert_purchase_payload_in_current_organization%'
  AND pg_get_functiondef('public.create_purchase_order_v1(uuid,bigint,bigint,timestamptz,timestamptz,text,jsonb)'::regprocedure)
    ILIKE '%WHERE organization_id=v_org AND request_id=p_request_id%',
  'crear OC valida payload e idempotencia por tenant'
);
SELECT ok(
  pg_get_functiondef('public.list_purchase_orders_v1(text,integer)'::regprocedure)
    ILIKE '%WHERE o.organization_id=v_org%',
  'listar OC filtra tenant'
);
SELECT ok(
  pg_get_functiondef('public.cancel_purchase_order_v1(bigint,text)'::regprocedure)
    ILIKE '%private.assert_purchase_order_in_current_organization%'
  AND pg_get_functiondef('public.cancel_purchase_order_v1(bigint,text)'::regprocedure)
    ILIKE '%WHERE organization_id=v_org AND id=p_purchase_order_id%',
  'anular OC valida y muta tenant actual'
);
SELECT ok(
  pg_get_functiondef('public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)'::regprocedure)
    ILIKE '%WHERE r.organization_id=v_org AND r.request_id=p_request_id%'
  AND pg_get_functiondef('public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)'::regprocedure)
    NOT ILIKE '%organization_id IS DISTINCT FROM v_org%',
  'recepción idempotente no infiere requests de otros tenants'
);

SELECT ok(
  pg_get_functiondef('public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)'::regprocedure)
    ILIKE '%private.assert_supplier_in_current_organization%'
  AND pg_get_functiondef('public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)'::regprocedure)
    ILIKE '%private.require_open_cash_session_id()%'
  AND pg_get_functiondef('public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)'::regprocedure)
    ILIKE '%private.cash_session_available_balance%'
  AND pg_get_functiondef('public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)'::regprocedure)
    NOT ILIKE '%disabled until cash sessions are tenant-aware%',
  'registrar gasto valida proveedor y usa caja tenant-aware cuando corresponde'
);
SELECT ok(
  pg_get_functiondef('public.eliminar_gasto_v1(bigint)'::regprocedure)
    ILIKE '%private.assert_expense_in_current_organization%'
  AND pg_get_functiondef('public.eliminar_pago_gasto_v1(bigint,bigint)'::regprocedure)
    ILIKE '%private.assert_expense_payment_in_current_organization%',
  'eliminación de gasto/pago valida tenant'
);
SELECT ok(
  pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%purchases.manage%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%private.assert_expense_in_current_organization(p_deuda_id)%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%private.require_open_cash_session_id()%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    NOT ILIKE '%disabled until cash sessions are tenant-aware%',
  'pago deuda proveedor exige permiso/tenant y caja tenant-aware'
);
SELECT ok(
  EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='pagos_deuda_requests_validate_target_tenant' AND NOT tgisinternal),
  'pagos_deuda_requests valida target polimórfico por tenant'
);

SELECT ok(NOT has_function_privilege('authenticated','public.receive_purchase_order_v1(uuid,bigint,timestamptz,text,text,jsonb)','EXECUTE'),'receive_purchase_order_v1 legacy no es endpoint cliente');
SELECT ok(NOT has_function_privilege('authenticated','public.registrar_gasto(bigint,text,numeric,numeric,text,text,timestamptz,boolean)','EXECUTE'),'registrar_gasto legacy no es endpoint cliente');
SELECT ok(
  has_function_privilege('authenticated','public.create_purchase_order_v1(uuid,bigint,bigint,timestamptz,timestamptz,text,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.receive_purchase_order_v2(uuid,bigint,timestamptz,text,text,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)','EXECUTE')
  AND has_function_privilege('authenticated','public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)','EXECUTE'),
  'allowlist cliente conserva sólo entrypoints vigentes'
);

SELECT * FROM finish();
ROLLBACK;
