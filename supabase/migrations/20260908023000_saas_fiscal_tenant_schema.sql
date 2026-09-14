-- Fase 3.7 SaaS (schema): perfil operativo fiscal, correlativos, documentos,
-- notas de crédito, GRE, bajas y procesos tributarios por organización.
BEGIN;

-- gre_ubigeos permanece global/read-only: es catálogo geográfico nacional.

ALTER TABLE public.series_comprobantes ADD COLUMN organization_id uuid;
ALTER TABLE public.comprobantes_electronicos ADD COLUMN organization_id uuid;
ALTER TABLE public.facturacion_intentos ADD COLUMN organization_id uuid;
ALTER TABLE public.notas_credito ADD COLUMN organization_id uuid;
ALTER TABLE public.notas_credito_detalles ADD COLUMN organization_id uuid;
ALTER TABLE public.notas_credito_intentos ADD COLUMN organization_id uuid;
ALTER TABLE public.gre_transportistas ADD COLUMN organization_id uuid;
ALTER TABLE public.gre_transportistas_agencias ADD COLUMN organization_id uuid;
ALTER TABLE public.gre_conductores ADD COLUMN organization_id uuid;
ALTER TABLE public.gre_vehiculos ADD COLUMN organization_id uuid;
ALTER TABLE public.guias_remision ADD COLUMN organization_id uuid;
ALTER TABLE public.guias_remision_detalles ADD COLUMN organization_id uuid;
ALTER TABLE public.guias_remision_intentos ADD COLUMN organization_id uuid;
ALTER TABLE public.solicitudes_baja_tributaria ADD COLUMN organization_id uuid;
ALTER TABLE public.procesos_tributarios ADD COLUMN organization_id uuid;
ALTER TABLE public.procesos_tributarios_detalles ADD COLUMN organization_id uuid;
ALTER TABLE public.procesos_tributarios_intentos ADD COLUMN organization_id uuid;
ALTER TABLE public.correlativos_procesos_tributarios ADD COLUMN organization_id uuid;
ALTER TABLE public.documentos_tributarios_reconciliaciones ADD COLUMN organization_id uuid;

COMMENT ON COLUMN public.series_comprobantes.organization_id IS 'Tenant propietario de la serie y su correlativo.';
COMMENT ON COLUMN public.comprobantes_electronicos.organization_id IS 'Tenant propietario del comprobante electrónico.';
COMMENT ON COLUMN public.notas_credito.organization_id IS 'Tenant propietario de la nota de crédito.';
COMMENT ON COLUMN public.guias_remision.organization_id IS 'Tenant propietario de la GRE.';
COMMENT ON COLUMN public.procesos_tributarios.organization_id IS 'Tenant propietario del proceso tributario.';

-- -----------------------------------------------------------------------------
-- Backfill: primero derivar desde dominios ya tenant-aware; sólo datos legacy
-- sin relación resoluble pueden usar el fallback de una única organización.
-- -----------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_needs_fallback boolean;
  v_org_count integer;
  v_fallback_org uuid;
BEGIN
  UPDATE public.comprobantes_electronicos ce
  SET organization_id=v.organization_id
  FROM public.ventas v
  WHERE ce.organization_id IS NULL AND v.id=ce.venta_id;

  UPDATE public.facturacion_intentos fi
  SET organization_id=ce.organization_id
  FROM public.comprobantes_electronicos ce
  WHERE fi.organization_id IS NULL AND ce.id=fi.comprobante_id;

  UPDATE public.notas_credito nc
  SET organization_id=ce.organization_id
  FROM public.comprobantes_electronicos ce
  WHERE nc.organization_id IS NULL AND ce.id=nc.comprobante_id;

  UPDATE public.notas_credito nc
  SET organization_id=v.organization_id
  FROM public.ventas v
  WHERE nc.organization_id IS NULL AND v.id=nc.venta_id;

  UPDATE public.notas_credito_detalles d
  SET organization_id=n.organization_id
  FROM public.notas_credito n
  WHERE d.organization_id IS NULL AND n.id=d.nota_credito_id;

  UPDATE public.notas_credito_intentos i
  SET organization_id=n.organization_id
  FROM public.notas_credito n
  WHERE i.organization_id IS NULL AND n.id=i.nota_credito_id;

  -- Solicitudes de baja derivan siempre del documento/venta origen cuando existe.
  UPDATE public.solicitudes_baja_tributaria s
  SET organization_id=ce.organization_id
  FROM public.comprobantes_electronicos ce
  WHERE s.organization_id IS NULL AND s.comprobante_id=ce.id;

  UPDATE public.solicitudes_baja_tributaria s
  SET organization_id=nc.organization_id
  FROM public.notas_credito nc
  WHERE s.organization_id IS NULL AND s.nota_credito_id=nc.id;

  UPDATE public.solicitudes_baja_tributaria s
  SET organization_id=v.organization_id
  FROM public.ventas v
  WHERE s.organization_id IS NULL AND s.venta_id=v.id;

  -- Detalles tributarios pueden resolver el tenant desde la solicitud o venta.
  UPDATE public.procesos_tributarios_detalles d
  SET organization_id=s.organization_id
  FROM public.solicitudes_baja_tributaria s
  WHERE d.organization_id IS NULL AND d.solicitud_id=s.id;

  UPDATE public.procesos_tributarios_detalles d
  SET organization_id=v.organization_id
  FROM public.ventas v
  WHERE d.organization_id IS NULL AND d.venta_id=v.id;

  -- Proceso: sólo derivar si todos sus detalles resueltos pertenecen a un tenant.
  UPDATE public.procesos_tributarios p
  SET organization_id=x.organization_id
  FROM (
    SELECT proceso_id,min(organization_id) organization_id
    FROM public.procesos_tributarios_detalles
    WHERE organization_id IS NOT NULL
    GROUP BY proceso_id
    HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE p.organization_id IS NULL AND p.id=x.proceso_id;

  UPDATE public.solicitudes_baja_tributaria s
  SET organization_id=p.organization_id
  FROM public.procesos_tributarios p
  WHERE s.organization_id IS NULL AND s.proceso_id=p.id;

  UPDATE public.procesos_tributarios_intentos i
  SET organization_id=p.organization_id
  FROM public.procesos_tributarios p
  WHERE i.organization_id IS NULL AND i.proceso_id=p.id;

  UPDATE public.correlativos_procesos_tributarios c
  SET organization_id=x.organization_id
  FROM (
    SELECT tipo_proceso,fecha_referencia,min(organization_id) organization_id
    FROM public.procesos_tributarios
    WHERE organization_id IS NOT NULL
    GROUP BY tipo_proceso,fecha_referencia
    HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE c.organization_id IS NULL
    AND c.tipo_proceso=x.tipo_proceso
    AND c.fecha_referencia=x.fecha_referencia;

  -- GRE: cabecera desde venta/comprobante/transferencia cuando hay origen.
  UPDATE public.guias_remision g
  SET organization_id=v.organization_id
  FROM public.ventas v
  WHERE g.organization_id IS NULL AND g.venta_id=v.id;

  UPDATE public.guias_remision g
  SET organization_id=ce.organization_id
  FROM public.comprobantes_electronicos ce
  WHERE g.organization_id IS NULL AND g.comprobante_id=ce.id;

  UPDATE public.guias_remision g
  SET organization_id=t.organization_id
  FROM public.transferencias_stock t
  WHERE g.organization_id IS NULL AND g.transferencia_id=t.id;

  UPDATE public.guias_remision_detalles d
  SET organization_id=g.organization_id
  FROM public.guias_remision g
  WHERE d.organization_id IS NULL AND d.guia_id=g.id;

  UPDATE public.guias_remision_intentos i
  SET organization_id=g.organization_id
  FROM public.guias_remision g
  WHERE i.organization_id IS NULL AND i.guia_id=g.id;

  -- Catálogos GRE pueden derivar ownership de referencias históricas cuando
  -- un registro aparece exclusivamente en guías de una sola organización.
  UPDATE public.gre_transportistas t
  SET organization_id=x.organization_id
  FROM (
    SELECT id,min(organization_id) organization_id
    FROM (
      SELECT transportista_id id,organization_id FROM public.guias_remision WHERE transportista_id IS NOT NULL AND organization_id IS NOT NULL
      UNION ALL
      SELECT transportista_transbordo_id id,organization_id FROM public.guias_remision WHERE transportista_transbordo_id IS NOT NULL AND organization_id IS NOT NULL
    ) q
    GROUP BY id HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE t.organization_id IS NULL AND t.id=x.id;

  UPDATE public.gre_conductores c
  SET organization_id=x.organization_id
  FROM (
    SELECT conductor_id id,min(organization_id) organization_id
    FROM public.guias_remision
    WHERE conductor_id IS NOT NULL AND organization_id IS NOT NULL
    GROUP BY conductor_id HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE c.organization_id IS NULL AND c.id=x.id;

  UPDATE public.gre_vehiculos v
  SET organization_id=t.organization_id
  FROM public.gre_transportistas t
  WHERE v.organization_id IS NULL AND v.transportista_id=t.id AND t.organization_id IS NOT NULL;

  UPDATE public.gre_vehiculos v
  SET organization_id=x.organization_id
  FROM (
    SELECT vehiculo_id id,min(organization_id) organization_id
    FROM public.guias_remision
    WHERE vehiculo_id IS NOT NULL AND organization_id IS NOT NULL
    GROUP BY vehiculo_id HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE v.organization_id IS NULL AND v.id=x.id;

  UPDATE public.gre_transportistas_agencias a
  SET organization_id=t.organization_id
  FROM public.gre_transportistas t
  WHERE a.organization_id IS NULL AND a.transportista_id=t.id AND t.organization_id IS NOT NULL;

  UPDATE public.gre_transportistas_agencias a
  SET organization_id=x.organization_id
  FROM (
    SELECT id,min(organization_id) organization_id
    FROM (
      SELECT agencia_origen_id id,organization_id FROM public.guias_remision WHERE agencia_origen_id IS NOT NULL AND organization_id IS NOT NULL
      UNION ALL
      SELECT agencia_destino_id id,organization_id FROM public.guias_remision WHERE agencia_destino_id IS NOT NULL AND organization_id IS NOT NULL
    ) q
    GROUP BY id HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE a.organization_id IS NULL AND a.id=x.id;

  -- Series pueden derivarse de comprobantes ya emitidos si la combinación
  -- histórica sólo aparece en una organización.
  UPDATE public.series_comprobantes s
  SET organization_id=x.organization_id
  FROM (
    SELECT tipo_documento_sunat,serie,min(organization_id) organization_id
    FROM public.comprobantes_electronicos
    WHERE organization_id IS NOT NULL
    GROUP BY tipo_documento_sunat,serie
    HAVING count(DISTINCT organization_id)=1
  ) x
  WHERE s.organization_id IS NULL
    AND s.tipo_documento_sunat=x.tipo_documento_sunat
    AND s.serie=x.serie;

  -- Auditoría de reconciliación: target polimórfico.
  UPDATE public.documentos_tributarios_reconciliaciones r
  SET organization_id=ce.organization_id
  FROM public.comprobantes_electronicos ce
  WHERE r.organization_id IS NULL AND r.tipo_documento='comprobante' AND r.documento_id=ce.id;
  UPDATE public.documentos_tributarios_reconciliaciones r
  SET organization_id=nc.organization_id
  FROM public.notas_credito nc
  WHERE r.organization_id IS NULL AND r.tipo_documento='nota_credito' AND r.documento_id=nc.id;
  UPDATE public.documentos_tributarios_reconciliaciones r
  SET organization_id=g.organization_id
  FROM public.guias_remision g
  WHERE r.organization_id IS NULL AND r.tipo_documento='guia' AND r.documento_id=g.id;
  UPDATE public.documentos_tributarios_reconciliaciones r
  SET organization_id=p.organization_id
  FROM public.procesos_tributarios p
  WHERE r.organization_id IS NULL AND r.tipo_documento='proceso' AND r.documento_id=p.id;

  SELECT
    EXISTS(SELECT 1 FROM public.series_comprobantes WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.comprobantes_electronicos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.facturacion_intentos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.notas_credito WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.notas_credito_detalles WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.notas_credito_intentos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.gre_transportistas WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.gre_transportistas_agencias WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.gre_conductores WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.gre_vehiculos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.guias_remision WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.guias_remision_detalles WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.guias_remision_intentos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.solicitudes_baja_tributaria WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.procesos_tributarios WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.procesos_tributarios_detalles WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.procesos_tributarios_intentos WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.correlativos_procesos_tributarios WHERE organization_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.documentos_tributarios_reconciliaciones WHERE organization_id IS NULL)
  INTO v_needs_fallback;

  IF v_needs_fallback THEN
    SELECT count(DISTINCT organization_id)::integer INTO v_org_count
    FROM public.configuracion_negocio;
    IF v_org_count<>1 THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Ambiguous legacy fiscal state: unresolved rows require exactly one business organization';
    END IF;
    SELECT organization_id INTO v_fallback_org FROM public.configuracion_negocio ORDER BY organization_id::text LIMIT 1;

    UPDATE public.series_comprobantes SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.comprobantes_electronicos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.facturacion_intentos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.notas_credito SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.notas_credito_detalles SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.notas_credito_intentos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.gre_transportistas SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.gre_transportistas_agencias SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.gre_conductores SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.gre_vehiculos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.guias_remision SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.guias_remision_detalles SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.guias_remision_intentos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.solicitudes_baja_tributaria SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.procesos_tributarios SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.procesos_tributarios_detalles SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.procesos_tributarios_intentos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.correlativos_procesos_tributarios SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.documentos_tributarios_reconciliaciones SET organization_id=v_fallback_org WHERE organization_id IS NULL;
  END IF;
END;
$backfill$;

ALTER TABLE public.series_comprobantes ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.comprobantes_electronicos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.facturacion_intentos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.notas_credito ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.notas_credito_detalles ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.notas_credito_intentos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.gre_transportistas ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.gre_transportistas_agencias ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.gre_conductores ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.gre_vehiculos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.guias_remision ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.guias_remision_detalles ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.guias_remision_intentos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.solicitudes_baja_tributaria ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.procesos_tributarios ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.procesos_tributarios_detalles ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.procesos_tributarios_intentos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.correlativos_procesos_tributarios ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.documentos_tributarios_reconciliaciones ALTER COLUMN organization_id SET NOT NULL;

-- Ownership y claves compuestas de padres.
DO $ownership$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'series_comprobantes','comprobantes_electronicos','facturacion_intentos',
    'notas_credito','notas_credito_detalles','notas_credito_intentos',
    'gre_transportistas','gre_transportistas_agencias','gre_conductores','gre_vehiculos',
    'guias_remision','guias_remision_detalles','guias_remision_intentos',
    'solicitudes_baja_tributaria','procesos_tributarios','procesos_tributarios_detalles',
    'procesos_tributarios_intentos','documentos_tributarios_reconciliaciones'
  ] LOOP
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT',
      t,t || '_organization_id_fkey'
    );
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I UNIQUE (organization_id,id)',
      t,t || '_organization_id_id_key'
    );
  END LOOP;
END;
$ownership$;

ALTER TABLE public.correlativos_procesos_tributarios
  ADD CONSTRAINT correlativos_procesos_tributarios_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.correlativos_procesos_tributarios DROP CONSTRAINT correlativos_procesos_tributarios_pkey;
ALTER TABLE public.correlativos_procesos_tributarios
  ADD CONSTRAINT correlativos_procesos_tributarios_pkey PRIMARY KEY (organization_id,tipo_proceso,fecha_referencia);

-- Namespace fiscal por empresa.
ALTER TABLE public.series_comprobantes DROP CONSTRAINT series_comprobantes_unique;
ALTER TABLE public.series_comprobantes
  ADD CONSTRAINT series_comprobantes_unique UNIQUE (organization_id,tipo_documento_sunat,serie);

ALTER TABLE public.comprobantes_electronicos
  DROP CONSTRAINT comprobantes_electronicos_request_unique,
  DROP CONSTRAINT comprobantes_electronicos_unique;
ALTER TABLE public.comprobantes_electronicos
  ADD CONSTRAINT comprobantes_electronicos_request_unique UNIQUE (organization_id,request_id),
  ADD CONSTRAINT comprobantes_electronicos_unique UNIQUE (organization_id,tipo_documento_sunat,serie,correlativo);

ALTER TABLE public.notas_credito
  DROP CONSTRAINT notas_credito_request_id_key,
  DROP CONSTRAINT notas_credito_serie_correlativo_unique;
ALTER TABLE public.notas_credito
  ADD CONSTRAINT notas_credito_request_id_key UNIQUE (organization_id,request_id),
  ADD CONSTRAINT notas_credito_serie_correlativo_unique UNIQUE (organization_id,serie,correlativo);

ALTER TABLE public.guias_remision
  DROP CONSTRAINT guias_remision_request_id_key,
  DROP CONSTRAINT guias_remision_serie_correlativo_unique;
ALTER TABLE public.guias_remision
  ADD CONSTRAINT guias_remision_request_id_key UNIQUE (organization_id,request_id),
  ADD CONSTRAINT guias_remision_serie_correlativo_unique UNIQUE (organization_id,tipo_documento_sunat,serie,correlativo);

ALTER TABLE public.procesos_tributarios
  DROP CONSTRAINT procesos_tributarios_identificador_key,
  DROP CONSTRAINT procesos_tributarios_request_id_key,
  DROP CONSTRAINT procesos_tributarios_unique;
ALTER TABLE public.procesos_tributarios
  ADD CONSTRAINT procesos_tributarios_identificador_key UNIQUE (organization_id,identificador),
  ADD CONSTRAINT procesos_tributarios_request_id_key UNIQUE (organization_id,request_id),
  ADD CONSTRAINT procesos_tributarios_unique UNIQUE (organization_id,tipo_proceso,fecha_referencia,correlativo);

ALTER TABLE public.solicitudes_baja_tributaria DROP CONSTRAINT solicitudes_baja_tributaria_request_id_key;
ALTER TABLE public.solicitudes_baja_tributaria
  ADD CONSTRAINT solicitudes_baja_tributaria_request_id_key UNIQUE (organization_id,request_id);

ALTER TABLE public.gre_transportistas DROP CONSTRAINT gre_transportistas_ruc_unique;
ALTER TABLE public.gre_transportistas
  ADD CONSTRAINT gre_transportistas_ruc_unique UNIQUE (organization_id,ruc);
ALTER TABLE public.gre_conductores DROP CONSTRAINT gre_conductores_documento_unique;
ALTER TABLE public.gre_conductores
  ADD CONSTRAINT gre_conductores_documento_unique UNIQUE (organization_id,tipo_documento,numero_documento);
ALTER TABLE public.gre_vehiculos DROP CONSTRAINT gre_vehiculos_placa_unique;
ALTER TABLE public.gre_vehiculos
  ADD CONSTRAINT gre_vehiculos_placa_unique UNIQUE (organization_id,placa);

-- Parents tenant-aware de fases anteriores usados por FKs fiscales.
CREATE UNIQUE INDEX IF NOT EXISTS fiscal_detalle_ventas_organization_id_id_uidx
  ON public.detalle_ventas(organization_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS fiscal_transferencias_stock_organization_id_id_uidx
  ON public.transferencias_stock(organization_id,id);

-- Convertir FKs existentes a relaciones tenant-qualified.
ALTER TABLE public.comprobantes_electronicos
  DROP CONSTRAINT comprobantes_electronicos_venta_id_fkey,
  DROP CONSTRAINT comprobantes_solicitud_baja_id_fkey;
ALTER TABLE public.comprobantes_electronicos
  ADD CONSTRAINT comprobantes_electronicos_venta_id_fkey
    FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id),
  ADD CONSTRAINT comprobantes_solicitud_baja_id_fkey
    FOREIGN KEY (organization_id,solicitud_baja_id) REFERENCES public.solicitudes_baja_tributaria(organization_id,id) ON DELETE SET NULL (solicitud_baja_id);

ALTER TABLE public.facturacion_intentos DROP CONSTRAINT facturacion_intentos_comprobante_id_fkey;
ALTER TABLE public.facturacion_intentos
  ADD CONSTRAINT facturacion_intentos_comprobante_id_fkey
    FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.notas_credito
  DROP CONSTRAINT notas_credito_comprobante_id_fkey,
  DROP CONSTRAINT notas_credito_solicitud_baja_id_fkey,
  DROP CONSTRAINT notas_credito_venta_id_fkey;
ALTER TABLE public.notas_credito
  ADD CONSTRAINT notas_credito_comprobante_id_fkey
    FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id),
  ADD CONSTRAINT notas_credito_solicitud_baja_id_fkey
    FOREIGN KEY (organization_id,solicitud_baja_id) REFERENCES public.solicitudes_baja_tributaria(organization_id,id) ON DELETE SET NULL (solicitud_baja_id),
  ADD CONSTRAINT notas_credito_venta_id_fkey
    FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id);

ALTER TABLE public.notas_credito_detalles
  DROP CONSTRAINT notas_credito_detalles_almacen_id_fkey,
  DROP CONSTRAINT notas_credito_detalles_detalle_venta_id_fkey,
  DROP CONSTRAINT notas_credito_detalles_nota_credito_id_fkey,
  DROP CONSTRAINT notas_credito_detalles_producto_id_fkey;
ALTER TABLE public.notas_credito_detalles
  ADD CONSTRAINT notas_credito_detalles_almacen_id_fkey
    FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id),
  ADD CONSTRAINT notas_credito_detalles_detalle_venta_id_fkey
    FOREIGN KEY (organization_id,detalle_venta_id) REFERENCES public.detalle_ventas(organization_id,id),
  ADD CONSTRAINT notas_credito_detalles_nota_credito_id_fkey
    FOREIGN KEY (organization_id,nota_credito_id) REFERENCES public.notas_credito(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT notas_credito_detalles_producto_id_fkey
    FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id);

ALTER TABLE public.notas_credito_intentos DROP CONSTRAINT notas_credito_intentos_nota_credito_id_fkey;
ALTER TABLE public.notas_credito_intentos
  ADD CONSTRAINT notas_credito_intentos_nota_credito_id_fkey
    FOREIGN KEY (organization_id,nota_credito_id) REFERENCES public.notas_credito(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.gre_transportistas_agencias DROP CONSTRAINT gre_transportistas_agencias_transportista_id_fkey;
ALTER TABLE public.gre_transportistas_agencias
  ADD CONSTRAINT gre_transportistas_agencias_transportista_id_fkey
    FOREIGN KEY (organization_id,transportista_id) REFERENCES public.gre_transportistas(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.gre_vehiculos DROP CONSTRAINT gre_vehiculos_transportista_id_fkey;
ALTER TABLE public.gre_vehiculos
  ADD CONSTRAINT gre_vehiculos_transportista_id_fkey
    FOREIGN KEY (organization_id,transportista_id) REFERENCES public.gre_transportistas(organization_id,id) ON DELETE SET NULL (transportista_id);

ALTER TABLE public.guias_remision
  DROP CONSTRAINT guias_remision_agencia_destino_id_fkey,
  DROP CONSTRAINT guias_remision_agencia_origen_id_fkey,
  DROP CONSTRAINT guias_remision_comprobante_id_fkey,
  DROP CONSTRAINT guias_remision_conductor_id_fkey,
  DROP CONSTRAINT guias_remision_guia_remitente_id_fkey,
  DROP CONSTRAINT guias_remision_transferencia_id_fkey,
  DROP CONSTRAINT guias_remision_transportista_id_fkey,
  DROP CONSTRAINT guias_remision_transportista_transbordo_id_fkey,
  DROP CONSTRAINT guias_remision_vehiculo_id_fkey,
  DROP CONSTRAINT guias_remision_venta_id_fkey;
ALTER TABLE public.guias_remision
  ADD CONSTRAINT guias_remision_agencia_destino_id_fkey FOREIGN KEY (organization_id,agencia_destino_id) REFERENCES public.gre_transportistas_agencias(organization_id,id) ON DELETE SET NULL (agencia_destino_id),
  ADD CONSTRAINT guias_remision_agencia_origen_id_fkey FOREIGN KEY (organization_id,agencia_origen_id) REFERENCES public.gre_transportistas_agencias(organization_id,id) ON DELETE SET NULL (agencia_origen_id),
  ADD CONSTRAINT guias_remision_comprobante_id_fkey FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id) ON DELETE SET NULL (comprobante_id),
  ADD CONSTRAINT guias_remision_conductor_id_fkey FOREIGN KEY (organization_id,conductor_id) REFERENCES public.gre_conductores(organization_id,id) ON DELETE SET NULL (conductor_id),
  ADD CONSTRAINT guias_remision_guia_remitente_id_fkey FOREIGN KEY (organization_id,guia_remitente_id) REFERENCES public.guias_remision(organization_id,id) ON DELETE SET NULL (guia_remitente_id),
  ADD CONSTRAINT guias_remision_transferencia_id_fkey FOREIGN KEY (organization_id,transferencia_id) REFERENCES public.transferencias_stock(organization_id,id) ON DELETE SET NULL (transferencia_id),
  ADD CONSTRAINT guias_remision_transportista_id_fkey FOREIGN KEY (organization_id,transportista_id) REFERENCES public.gre_transportistas(organization_id,id) ON DELETE SET NULL (transportista_id),
  ADD CONSTRAINT guias_remision_transportista_transbordo_id_fkey FOREIGN KEY (organization_id,transportista_transbordo_id) REFERENCES public.gre_transportistas(organization_id,id) ON DELETE SET NULL (transportista_transbordo_id),
  ADD CONSTRAINT guias_remision_vehiculo_id_fkey FOREIGN KEY (organization_id,vehiculo_id) REFERENCES public.gre_vehiculos(organization_id,id) ON DELETE SET NULL (vehiculo_id),
  ADD CONSTRAINT guias_remision_venta_id_fkey FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id) ON DELETE SET NULL (venta_id);

ALTER TABLE public.guias_remision_detalles
  DROP CONSTRAINT guias_remision_detalles_almacen_id_fkey,
  DROP CONSTRAINT guias_remision_detalles_detalle_venta_id_fkey,
  DROP CONSTRAINT guias_remision_detalles_guia_id_fkey,
  DROP CONSTRAINT guias_remision_detalles_producto_id_fkey,
  DROP CONSTRAINT guias_remision_detalles_transferencia_id_fkey;
ALTER TABLE public.guias_remision_detalles
  ADD CONSTRAINT guias_remision_detalles_almacen_id_fkey FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id) ON DELETE SET NULL (almacen_id),
  ADD CONSTRAINT guias_remision_detalles_detalle_venta_id_fkey FOREIGN KEY (organization_id,detalle_venta_id) REFERENCES public.detalle_ventas(organization_id,id) ON DELETE SET NULL (detalle_venta_id),
  ADD CONSTRAINT guias_remision_detalles_guia_id_fkey FOREIGN KEY (organization_id,guia_id) REFERENCES public.guias_remision(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT guias_remision_detalles_producto_id_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE SET NULL (producto_id),
  ADD CONSTRAINT guias_remision_detalles_transferencia_id_fkey FOREIGN KEY (organization_id,transferencia_id) REFERENCES public.transferencias_stock(organization_id,id) ON DELETE SET NULL (transferencia_id);

ALTER TABLE public.guias_remision_intentos DROP CONSTRAINT guias_remision_intentos_guia_id_fkey;
ALTER TABLE public.guias_remision_intentos
  ADD CONSTRAINT guias_remision_intentos_guia_id_fkey FOREIGN KEY (organization_id,guia_id) REFERENCES public.guias_remision(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.procesos_tributarios_detalles
  DROP CONSTRAINT procesos_tributarios_detalles_comprobante_id_fkey,
  DROP CONSTRAINT procesos_tributarios_detalles_nota_credito_id_fkey,
  DROP CONSTRAINT procesos_tributarios_detalles_proceso_id_fkey,
  DROP CONSTRAINT procesos_tributarios_detalles_solicitud_id_fkey,
  DROP CONSTRAINT procesos_tributarios_detalles_venta_id_fkey,
  DROP CONSTRAINT procesos_tributarios_detalles_solicitud_id_key;
ALTER TABLE public.procesos_tributarios_detalles
  ADD CONSTRAINT procesos_tributarios_detalles_comprobante_id_fkey FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id),
  ADD CONSTRAINT procesos_tributarios_detalles_nota_credito_id_fkey FOREIGN KEY (organization_id,nota_credito_id) REFERENCES public.notas_credito(organization_id,id),
  ADD CONSTRAINT procesos_tributarios_detalles_proceso_id_fkey FOREIGN KEY (organization_id,proceso_id) REFERENCES public.procesos_tributarios(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT procesos_tributarios_detalles_solicitud_id_fkey FOREIGN KEY (organization_id,solicitud_id) REFERENCES public.solicitudes_baja_tributaria(organization_id,id),
  ADD CONSTRAINT procesos_tributarios_detalles_venta_id_fkey FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id),
  ADD CONSTRAINT procesos_tributarios_detalles_solicitud_id_key UNIQUE (organization_id,solicitud_id);

ALTER TABLE public.procesos_tributarios_intentos DROP CONSTRAINT procesos_tributarios_intentos_proceso_id_fkey;
ALTER TABLE public.procesos_tributarios_intentos
  ADD CONSTRAINT procesos_tributarios_intentos_proceso_id_fkey FOREIGN KEY (organization_id,proceso_id) REFERENCES public.procesos_tributarios(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.solicitudes_baja_tributaria
  DROP CONSTRAINT solicitudes_baja_proceso_id_fkey,
  DROP CONSTRAINT solicitudes_baja_tributaria_comprobante_id_fkey,
  DROP CONSTRAINT solicitudes_baja_tributaria_nota_credito_id_fkey,
  DROP CONSTRAINT solicitudes_baja_tributaria_venta_id_fkey;
ALTER TABLE public.solicitudes_baja_tributaria
  ADD CONSTRAINT solicitudes_baja_proceso_id_fkey FOREIGN KEY (organization_id,proceso_id) REFERENCES public.procesos_tributarios(organization_id,id) ON DELETE SET NULL (proceso_id),
  ADD CONSTRAINT solicitudes_baja_tributaria_comprobante_id_fkey FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id),
  ADD CONSTRAINT solicitudes_baja_tributaria_nota_credito_id_fkey FOREIGN KEY (organization_id,nota_credito_id) REFERENCES public.notas_credito(organization_id,id),
  ADD CONSTRAINT solicitudes_baja_tributaria_venta_id_fkey FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id);

-- Relación pendiente desde F3.5: constancia de descuento -> comprobante.
ALTER TABLE public.constancias_descuento DROP CONSTRAINT constancias_descuento_comprobante_id_fkey;
ALTER TABLE public.constancias_descuento
  ADD CONSTRAINT constancias_descuento_comprobante_id_fkey
    FOREIGN KEY (organization_id,comprobante_id) REFERENCES public.comprobantes_electronicos(organization_id,id) ON DELETE SET NULL (comprobante_id);

-- Tenant derivado server-side e inmutable en todas las tablas tenant-owned.
DO $triggers$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'series_comprobantes','comprobantes_electronicos','facturacion_intentos',
    'notas_credito','notas_credito_detalles','notas_credito_intentos',
    'gre_transportistas','gre_transportistas_agencias','gre_conductores','gre_vehiculos',
    'guias_remision','guias_remision_detalles','guias_remision_intentos',
    'solicitudes_baja_tributaria','procesos_tributarios','procesos_tributarios_detalles',
    'procesos_tributarios_intentos','correlativos_procesos_tributarios',
    'documentos_tributarios_reconciliaciones'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I',t || '_enforce_organization_id',t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id()',
      t || '_enforce_organization_id',t
    );
  END LOOP;
END;
$triggers$;

-- -----------------------------------------------------------------------------
-- RLS/grants. Documentos operativos tienen SELECT tenant; mutación sensible
-- continúa por RPC/Edge. Catálogos GRE conservan CRUD de UI con RLS tenant.
-- -----------------------------------------------------------------------------
DO $rls$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'series_comprobantes','comprobantes_electronicos','facturacion_intentos',
    'notas_credito','notas_credito_detalles','notas_credito_intentos',
    'gre_transportistas','gre_transportistas_agencias','gre_conductores','gre_vehiculos',
    'guias_remision','guias_remision_detalles','guias_remision_intentos',
    'solicitudes_baja_tributaria','procesos_tributarios','procesos_tributarios_detalles',
    'procesos_tributarios_intentos','correlativos_procesos_tributarios',
    'documentos_tributarios_reconciliaciones'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated',t);
  END LOOP;
END;
$rls$;

-- Retirar policies legacy conocidas.
DROP POLICY IF EXISTS comprobantes_select ON public.comprobantes_electronicos;
DROP POLICY IF EXISTS reconciliaciones_admin_select ON public.documentos_tributarios_reconciliaciones;
DROP POLICY IF EXISTS intentos_select_admin ON public.facturacion_intentos;
DROP POLICY IF EXISTS gre_conductores_operativos ON public.gre_conductores;
DROP POLICY IF EXISTS gre_transportistas_operativos ON public.gre_transportistas;
DROP POLICY IF EXISTS gre_transportistas_agencias_insert ON public.gre_transportistas_agencias;
DROP POLICY IF EXISTS gre_transportistas_agencias_select ON public.gre_transportistas_agencias;
DROP POLICY IF EXISTS gre_transportistas_agencias_update ON public.gre_transportistas_agencias;
DROP POLICY IF EXISTS gre_vehiculos_operativos ON public.gre_vehiculos;
DROP POLICY IF EXISTS guias_select ON public.guias_remision;
DROP POLICY IF EXISTS guias_detalles_select ON public.guias_remision_detalles;
DROP POLICY IF EXISTS guias_intentos_admin ON public.guias_remision_intentos;
DROP POLICY IF EXISTS notas_select ON public.notas_credito;
DROP POLICY IF EXISTS notas_detalles_select ON public.notas_credito_detalles;
DROP POLICY IF EXISTS notas_intentos_admin ON public.notas_credito_intentos;
DROP POLICY IF EXISTS procesos_admin ON public.procesos_tributarios;
DROP POLICY IF EXISTS procesos_detalles_admin ON public.procesos_tributarios_detalles;
DROP POLICY IF EXISTS procesos_intentos_admin ON public.procesos_tributarios_intentos;
DROP POLICY IF EXISTS series_select_empleado ON public.series_comprobantes;
DROP POLICY IF EXISTS solicitudes_baja_admin ON public.solicitudes_baja_tributaria;

-- Lectura operativa del tenant.
CREATE POLICY series_comprobantes_tenant_select ON public.series_comprobantes
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY comprobantes_electronicos_tenant_select ON public.comprobantes_electronicos
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY notas_credito_tenant_select ON public.notas_credito
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY notas_credito_detalles_tenant_select ON public.notas_credito_detalles
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY guias_remision_tenant_select ON public.guias_remision
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY guias_remision_detalles_tenant_select ON public.guias_remision_detalles
FOR SELECT TO authenticated USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

GRANT SELECT ON TABLE public.series_comprobantes TO authenticated;
GRANT SELECT ON TABLE public.comprobantes_electronicos TO authenticated;
GRANT SELECT ON TABLE public.notas_credito TO authenticated;
GRANT SELECT ON TABLE public.notas_credito_detalles TO authenticated;
GRANT SELECT ON TABLE public.guias_remision TO authenticated;
GRANT SELECT ON TABLE public.guias_remision_detalles TO authenticated;

-- Auditoría/estados internos: sólo admin del mismo tenant.
CREATE POLICY facturacion_intentos_tenant_admin_select ON public.facturacion_intentos
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY notas_credito_intentos_tenant_admin_select ON public.notas_credito_intentos
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY guias_remision_intentos_tenant_admin_select ON public.guias_remision_intentos
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY procesos_tributarios_tenant_admin_select ON public.procesos_tributarios
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY procesos_tributarios_detalles_tenant_admin_select ON public.procesos_tributarios_detalles
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY procesos_tributarios_intentos_tenant_admin_select ON public.procesos_tributarios_intentos
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY solicitudes_baja_tributaria_tenant_admin_select ON public.solicitudes_baja_tributaria
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY documentos_tributarios_reconciliaciones_tenant_admin_select ON public.documentos_tributarios_reconciliaciones
FOR SELECT TO authenticated USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));

GRANT SELECT ON TABLE public.facturacion_intentos TO authenticated;
GRANT SELECT ON TABLE public.notas_credito_intentos TO authenticated;
GRANT SELECT ON TABLE public.guias_remision_intentos TO authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios TO authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios_detalles TO authenticated;
GRANT SELECT ON TABLE public.procesos_tributarios_intentos TO authenticated;
GRANT SELECT ON TABLE public.solicitudes_baja_tributaria TO authenticated;
GRANT SELECT ON TABLE public.documentos_tributarios_reconciliaciones TO authenticated;

-- Catálogos de transporte usados directamente por Flutter.
DO $gre_policies$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['gre_transportistas','gre_transportistas_agencias','gre_conductores','gre_vehiculos'] LOOP
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (private.has_permission(''tenant.read'') AND private.row_belongs_to_current_organization(organization_id))',
      t || '_tenant_select',t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (private.has_permission(''tenant.write'') AND private.row_belongs_to_current_organization(organization_id))',
      t || '_tenant_insert',t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (private.has_permission(''tenant.write'') AND private.row_belongs_to_current_organization(organization_id)) WITH CHECK (private.has_permission(''tenant.write'') AND private.row_belongs_to_current_organization(organization_id))',
      t || '_tenant_update',t
    );
    EXECUTE format('GRANT SELECT,INSERT,UPDATE ON TABLE public.%I TO authenticated',t);
  END LOOP;
END;
$gre_policies$;

CREATE INDEX series_comprobantes_organization_id_idx ON public.series_comprobantes(organization_id);
CREATE INDEX comprobantes_electronicos_organization_id_idx ON public.comprobantes_electronicos(organization_id);
CREATE INDEX notas_credito_organization_id_idx ON public.notas_credito(organization_id);
CREATE INDEX guias_remision_organization_id_idx ON public.guias_remision(organization_id);
CREATE INDEX procesos_tributarios_organization_id_idx ON public.procesos_tributarios(organization_id);
CREATE INDEX solicitudes_baja_tributaria_organization_id_idx ON public.solicitudes_baja_tributaria(organization_id);

COMMIT;
