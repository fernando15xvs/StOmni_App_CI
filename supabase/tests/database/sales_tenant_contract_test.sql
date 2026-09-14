BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(30);

SELECT ok(
  (SELECT bool_and(attnotnull) FROM pg_attribute
   WHERE attrelid IN (
     'public.ventas'::regclass,'public.detalle_ventas'::regclass,'public.pagos_venta'::regclass,
     'public.cotizaciones'::regclass,'public.detalle_cotizaciones'::regclass,
     'public.pagos_deuda_requests'::regclass,'public.ventas_requests_anulados'::regclass,
     'public.constancias_descuento'::regclass
   ) AND attname='organization_id' AND NOT attisdropped),
  'tablas comerciales tienen organization_id NOT NULL'
);

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='ventas_organization_id_id_key' AND contype='u'),'ventas expone clave compuesta tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='cotizaciones_organization_id_id_key' AND contype='u'),'cotizaciones expone clave compuesta tenant');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_constraint
  WHERE conrelid='public.pagos_deuda_requests'::regclass
    AND conname='pagos_deuda_requests_pkey'
    AND contype='p'
    AND pg_get_constraintdef(oid) ILIKE '%PRIMARY KEY (organization_id, request_id)%'
),'request de deuda tiene PK compuesta tenant');

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='ventas_cliente_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, cliente_id)%REFERENCES clientes(organization_id, id)%'),'venta/cliente tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='ventas_vendedor_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, vendedor_id)%REFERENCES empleados(organization_id, id)%'),'venta/vendedor tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='detalle_ventas_venta_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, venta_id)%REFERENCES ventas(organization_id, id)%'),'detalle/venta tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='detalle_ventas_producto_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, producto_id)%REFERENCES productos(organization_id, id)%'),'detalle/producto tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='detalle_ventas_almacen_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, almacen_id)%REFERENCES almacenes(organization_id, id)%'),'detalle/almacén tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='pagos_venta_venta_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, venta_id)%REFERENCES ventas(organization_id, id)%'),'pago/venta tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='pagos_venta_request_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, request_id)%REFERENCES pagos_deuda_requests(organization_id, request_id)%'),'pago/request tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='detalle_cotizaciones_cotizacion_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, cotizacion_id)%REFERENCES cotizaciones(organization_id, id)%'),'detalle/cotización tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='constancias_descuento_venta_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, venta_id)%REFERENCES ventas(organization_id, id)%'),'constancia/venta tenant-qualified');

SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='constancias_descuento' AND indexname='constancias_descuento_organization_codigo_key' AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%organization_id%' AND indexdef ILIKE '%codigo%'),'código de constancia único por tenant');

SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='ventas' AND policyname='ventas_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'ventas SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='cotizaciones' AND policyname='cotizaciones_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'cotizaciones SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='constancias_descuento' AND policyname='constancias_descuento_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'constancias SELECT tenant-aware');
SELECT ok(NOT has_table_privilege('anon','public.ventas','SELECT') AND NOT has_table_privilege('anon','public.cotizaciones','SELECT'),'anon no lee ventas/cotizaciones');
SELECT ok(NOT has_table_privilege('authenticated','public.pagos_deuda_requests','SELECT'),'tabla idempotencia de deuda no es lectura cliente');

SELECT ok(
  pg_get_functiondef('public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%private.assert_sales_payload_in_current_organization%'
  AND pg_get_functiondef('public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%ticket_interno%boleta%factura%'
  AND pg_get_functiondef('public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    NOT ILIKE '%temporarily disabled until fiscal tenant rollout F3.7%',
  'process_sale_v4 valida tenant y admite sólo documentos fiscales soportados'
);
SELECT ok(
  pg_get_functiondef('public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%private.assert_sales_payload_in_current_organization%',
  'process_sale_with_units_v4 valida tenant antes de consumir trazabilidad'
);
SELECT ok(
  pg_get_functiondef('public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%cn.organization_id = private.require_current_organization_id()%'
  AND pg_get_functiondef('public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%ia.organization_id = private.require_current_organization_id()%'
  AND pg_get_functiondef('public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%c.organization_id = private.require_current_organization_id()%','motor v3 interno fue parcheado a tenant');
SELECT ok(NOT has_function_privilege('authenticated','public.process_sale_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)','EXECUTE'),'process_sale_v3 no es endpoint cliente');
SELECT ok(NOT has_function_privilege('authenticated','public.process_sale_with_units_v3(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)','EXECUTE'),'process_sale_with_units_v3 no es endpoint cliente');
SELECT ok(has_function_privilege('authenticated','public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)','EXECUTE'),'process_sale_v4 está en allowlist');
SELECT ok(has_function_privilege('authenticated','public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)','EXECUTE'),'process_sale_with_units_v4 está en allowlist');

SELECT ok(
  pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%sales.create%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%private.assert_sale_in_current_organization(p_deuda_id)%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    ILIKE '%private.require_open_cash_session_id()%'
  AND pg_get_functiondef('public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure)
    NOT ILIKE '%disabled until cash sessions are tenant-aware%',
  'pago deuda cliente usa permisos, tenant y caja tenant-aware'
);
SELECT ok(
  pg_get_functiondef('public.anular_venta_v2(bigint,text)'::regprocedure)
    ILIKE '%private.assert_sale_in_current_organization(p_venta_id)%'
  AND pg_get_functiondef('public.eliminar_pago_venta_v1(bigint,bigint)'::regprocedure)
    ILIKE '%private.assert_sale_payment_in_current_organization%',
  'anulación y eliminación de pago validan tenant'
);

SELECT ok(
  pg_get_functiondef('public.anular_venta_v2_unscaled_legacy(bigint,text)'::regprocedure)
    ILIKE '%e.organization_id = private.require_current_organization_id()%'
  AND pg_get_functiondef('public.anular_venta_v2_unscaled_legacy(bigint,text)'::regprocedure)
    ILIKE '%dv.organization_id = private.require_current_organization_id()%'
  AND NOT has_function_privilege('authenticated','public.anular_venta_v2_unscaled_legacy(bigint,text)','EXECUTE'),
  'motor legacy de anulación queda tenant-scopeado y privado'
);
SELECT ok(
  to_regprocedure('public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)') IS NULL,
  'motor legacy de cobro fue retirado y no puede reintroducirse'
);

SELECT * FROM finish();
ROLLBACK;
