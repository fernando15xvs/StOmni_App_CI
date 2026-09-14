BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(39);

SELECT ok(
  (SELECT count(*)=19 AND bool_and(a.attnotnull)
   FROM pg_attribute a
   WHERE a.attrelid IN (
     'public.series_comprobantes'::regclass,
     'public.comprobantes_electronicos'::regclass,
     'public.facturacion_intentos'::regclass,
     'public.notas_credito'::regclass,
     'public.notas_credito_detalles'::regclass,
     'public.notas_credito_intentos'::regclass,
     'public.gre_transportistas'::regclass,
     'public.gre_transportistas_agencias'::regclass,
     'public.gre_conductores'::regclass,
     'public.gre_vehiculos'::regclass,
     'public.guias_remision'::regclass,
     'public.guias_remision_detalles'::regclass,
     'public.guias_remision_intentos'::regclass,
     'public.solicitudes_baja_tributaria'::regclass,
     'public.procesos_tributarios'::regclass,
     'public.procesos_tributarios_detalles'::regclass,
     'public.procesos_tributarios_intentos'::regclass,
     'public.correlativos_procesos_tributarios'::regclass,
     'public.documentos_tributarios_reconciliaciones'::regclass
   ) AND a.attname='organization_id' AND NOT a.attisdropped),
  '19 tablas fiscales/GRE tienen organization_id NOT NULL'
);

SELECT ok(
  (SELECT count(*)=19 AND bool_and(c.relrowsecurity)
   FROM pg_class c
   WHERE c.oid IN (
     'public.series_comprobantes'::regclass,
     'public.comprobantes_electronicos'::regclass,
     'public.facturacion_intentos'::regclass,
     'public.notas_credito'::regclass,
     'public.notas_credito_detalles'::regclass,
     'public.notas_credito_intentos'::regclass,
     'public.gre_transportistas'::regclass,
     'public.gre_transportistas_agencias'::regclass,
     'public.gre_conductores'::regclass,
     'public.gre_vehiculos'::regclass,
     'public.guias_remision'::regclass,
     'public.guias_remision_detalles'::regclass,
     'public.guias_remision_intentos'::regclass,
     'public.solicitudes_baja_tributaria'::regclass,
     'public.procesos_tributarios'::regclass,
     'public.procesos_tributarios_detalles'::regclass,
     'public.procesos_tributarios_intentos'::regclass,
     'public.correlativos_procesos_tributarios'::regclass,
     'public.documentos_tributarios_reconciliaciones'::regclass
   )),
  '19 tablas fiscales/GRE tienen RLS habilitado'
);

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='series_comprobantes_unique' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, tipo_documento_sunat, serie)%'),'series son únicas por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='comprobantes_electronicos_request_unique' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'request de comprobante es tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='comprobantes_electronicos_unique' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, tipo_documento_sunat, serie, correlativo)%'),'numeración de comprobante es tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='notas_credito_request_id_key' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'request de nota es tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='guias_remision_request_id_key' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'request de GRE es tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='procesos_tributarios_request_id_key' AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, request_id)%'),'request tributario es tenant-scoped');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='correlativos_procesos_tributarios_pkey' AND pg_get_constraintdef(oid) ILIKE '%PRIMARY KEY (organization_id, tipo_proceso, fecha_referencia)%'),'correlativos tributarios son tenant-scoped');

SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='comprobantes_electronicos_venta_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, venta_id)%REFERENCES ventas(organization_id, id)%'),'comprobante/venta tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='facturacion_intentos_comprobante_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, comprobante_id)%REFERENCES comprobantes_electronicos(organization_id, id)%'),'intento/comprobante tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='notas_credito_comprobante_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, comprobante_id)%REFERENCES comprobantes_electronicos(organization_id, id)%'),'nota/comprobante tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='notas_credito_detalles_nota_credito_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, nota_credito_id)%REFERENCES notas_credito(organization_id, id)%'),'detalle nota/nota tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='guias_remision_venta_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, venta_id)%REFERENCES ventas(organization_id, id)%'),'GRE/venta tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='guias_remision_detalles_guia_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, guia_id)%REFERENCES guias_remision(organization_id, id)%'),'detalle GRE/GRE tenant-qualified');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='procesos_tributarios_detalles_proceso_id_fkey' AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id, proceso_id)%REFERENCES procesos_tributarios(organization_id, id)%'),'detalle proceso/proceso tenant-qualified');

SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='comprobantes_electronicos' AND policyname='comprobantes_electronicos_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'comprobantes SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notas_credito' AND policyname='notas_credito_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'notas SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='guias_remision' AND policyname='guias_remision_tenant_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'GRE SELECT tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='procesos_tributarios' AND policyname='procesos_tributarios_tenant_admin_select' AND qual ILIKE '%row_belongs_to_current_organization(organization_id)%'),'procesos tributarios SELECT admin tenant-aware');

SELECT ok(
  pg_get_functiondef('public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%v_tipo NOT IN (''ticket_interno'',''boleta'',''factura'')%'
  AND pg_get_functiondef('public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    NOT ILIKE '%temporarily disabled until fiscal tenant rollout F3.7%',
  'process_sale_v4 reabre boleta/factura después del scope fiscal'
);
SELECT ok(
  pg_get_functiondef('public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)
    ILIKE '%v_tipo NOT IN (''ticket_interno'',''boleta'',''factura'')%',
  'process_sale_with_units_v4 reabre boleta/factura'
);
SELECT ok(
  pg_get_functiondef('public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)'::regprocedure)
    ILIKE '%private.assert_credit_note_payload_in_current_organization%'
  AND pg_get_functiondef('public.obtener_disponibilidad_nota_credito_v2(uuid)'::regprocedure)
    ILIKE '%private.assert_fiscal_comprobante_in_current_organization%',
  'entrypoints de nota validan tenant antes del motor legacy'
);
SELECT ok(
  pg_get_functiondef('public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamptz,timestamptz,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)'::regprocedure)
    ILIKE '%private.assert_gre_payload_in_current_organization%',
  'guardar GRE v4 valida payload tenant'
);
SELECT ok(
  pg_get_functiondef('public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer)'::regprocedure)
    ILIKE '%WHERE ce.organization_id=v_org%'
  AND pg_get_functiondef('public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer)'::regprocedure)
    ILIKE '%WHERE nc.organization_id=v_org%'
  AND pg_get_functiondef('public.listar_documentos_electronicos_v1(timestamptz,timestamptz,integer,integer)'::regprocedure)
    ILIKE '%WHERE g.organization_id=v_org%',
  'listado fiscal sólo une documentos del tenant actual'
);
SELECT ok(
  pg_get_functiondef('public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure)
    ILIKE '%organization_id = private.require_current_organization_id()%'
  OR pg_get_functiondef('public.solicitar_baja_tributaria_v1(uuid,text,uuid,text)'::regprocedure)
    ILIKE '%organization_id=private.require_current_organization_id()%'
  ,'baja tributaria scopea request y origen por tenant'
);

SELECT ok(
  pg_get_functiondef('private.service_request_organization_id()'::regprocedure)
    ILIKE '%x-stomni-organization-id%'
  AND pg_get_functiondef('private.require_service_organization_id()'::regprocedure)
    ILIKE '%organizations%status=''active''%',
  'RPC service_role requieren tenant interno verificado'
);
SELECT ok(
  NOT has_function_privilege('authenticated','public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.nota_credito_claim(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.gre_claim_v2(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)','EXECUTE'),
  'claims internos no son ejecutables por authenticated'
);
SELECT ok(
  has_function_privilege('service_role','public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND has_function_privilege('service_role','public.nota_credito_claim(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND has_function_privilege('service_role','public.gre_claim_v2(uuid,uuid,text,boolean,boolean)','EXECUTE')
  AND has_function_privilege('service_role','public.tributario_claim_proceso(uuid,uuid,text,boolean,boolean)','EXECUTE'),
  'claims internos conservan ejecución service_role'
);
SELECT ok(
  pg_get_functiondef('public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id = private.require_service_organization_id()%'
  AND pg_get_functiondef('public.facturacion_claim_comprobante(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id, comprobante_id, numero_intento%',
  'claim de comprobante valida tenant y crea intento tenant-owned'
);
SELECT ok(
  pg_get_functiondef('public.nota_credito_claim(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id = private.require_service_organization_id()%'
  AND pg_get_functiondef('public.nota_credito_claim(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id,%nota_credito_id,%numero_intento%',
  'claim de nota valida tenant y crea intento tenant-owned'
);
SELECT ok(
  pg_get_functiondef('public.gre_claim_v2(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id = private.require_service_organization_id()%'
  AND pg_get_functiondef('public.gre_claim_v2(uuid,uuid,text,boolean,boolean)'::regprocedure)
    ILIKE '%organization_id, guia_id, numero_intento%',
  'claim de GRE valida tenant y crea intento tenant-owned'
);
SELECT ok(
  pg_get_functiondef('public.tributario_preparar_procesos(text,uuid,boolean,integer)'::regprocedure)
    ILIKE '%ON CONFLICT (organization_id,tipo_proceso,fecha_referencia)%'
  AND pg_get_functiondef('public.tributario_preparar_procesos(text,uuid,boolean,integer)'::regprocedure)
    ILIKE '%WHERE s.organization_id=v_org%',
  'preparador tributario agrupa y correlaciona sólo dentro del tenant'
);
SELECT ok(
  NOT has_function_privilege('authenticated','public.tributario_preparar_procesos(text,uuid,boolean,integer)','EXECUTE')
  AND has_function_privilege('service_role','public.tributario_preparar_procesos(text,uuid,boolean,integer)','EXECUTE'),
  'preparación tributaria manual permanece sólo en service_role'
);

SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zz_comprobantes_fiscal_storage_paths' AND NOT tgisinternal),'comprobantes normalizan Storage tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zz_notas_credito_fiscal_storage_paths' AND NOT tgisinternal),'notas normalizan Storage tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zz_guias_remision_fiscal_storage_paths' AND NOT tgisinternal),'GRE normaliza Storage tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zz_procesos_tributarios_fiscal_storage_paths' AND NOT tgisinternal),'procesos normalizan Storage tenant');
SELECT ok(
  pg_get_functiondef('private.normalize_fiscal_storage_paths()'::regprocedure)
    ILIKE '%NEW.organization_id::text || ''/''%'
  AND pg_get_functiondef('private.normalize_fiscal_storage_paths()'::regprocedure)
    ILIKE '%organization_id%',
  'normalizador Storage persiste namespace <organization_id>/'
);

SELECT * FROM finish();
ROLLBACK;
