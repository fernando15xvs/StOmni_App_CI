-- Fase 3.5 SaaS (esquema): ventas, cotizaciones, pagos e idempotencia por organización.
-- Los RPC comerciales se endurecen en migraciones posteriores de la misma fase.
BEGIN;

ALTER TABLE public.ventas ADD COLUMN organization_id uuid;
ALTER TABLE public.detalle_ventas ADD COLUMN organization_id uuid;
ALTER TABLE public.pagos_venta ADD COLUMN organization_id uuid;
ALTER TABLE public.cotizaciones ADD COLUMN organization_id uuid;
ALTER TABLE public.detalle_cotizaciones ADD COLUMN organization_id uuid;
ALTER TABLE public.pagos_deuda_requests ADD COLUMN organization_id uuid;
ALTER TABLE public.ventas_requests_anulados ADD COLUMN organization_id uuid;

COMMENT ON COLUMN public.ventas.organization_id IS 'Tenant propietario de la venta.';
COMMENT ON COLUMN public.detalle_ventas.organization_id IS 'Tenant propietario del detalle de venta.';
COMMENT ON COLUMN public.pagos_venta.organization_id IS 'Tenant propietario del pago de venta.';
COMMENT ON COLUMN public.cotizaciones.organization_id IS 'Tenant propietario de la cotización.';
COMMENT ON COLUMN public.detalle_cotizaciones.organization_id IS 'Tenant propietario del detalle de cotización.';
COMMENT ON COLUMN public.pagos_deuda_requests.organization_id IS 'Tenant propietario de la solicitud idempotente de pago de deuda.';
COMMENT ON COLUMN public.ventas_requests_anulados.organization_id IS 'Tenant propietario del request de venta anulado.';

-- empleados.id es globalmente único, pero la clave compuesta permite que las FKs
-- comerciales prueben además pertenencia al tenant sin depender sólo del RPC.
CREATE UNIQUE INDEX IF NOT EXISTS empleados_organization_id_id_uidx
  ON public.empleados (organization_id, id);

DO $backfill$
DECLARE
  v_needs_fallback boolean;
  v_organization_count integer;
  v_fallback_organization_id uuid;
BEGIN
  -- Cabeceras: derivar primero desde relaciones ya tenant-aware.
  UPDATE public.ventas AS v
  SET organization_id = c.organization_id
  FROM public.clientes AS c
  WHERE v.organization_id IS NULL
    AND v.cliente_id = c.id;

  UPDATE public.ventas AS v
  SET organization_id = e.organization_id
  FROM public.empleados AS e
  WHERE v.organization_id IS NULL
    AND v.vendedor_id = e.id;

  UPDATE public.ventas AS v
  SET organization_id = e.organization_id
  FROM public.empleados AS e
  WHERE v.organization_id IS NULL
    AND v.descuento_autorizado_por = e.id;

  UPDATE public.cotizaciones AS c
  SET organization_id = cl.organization_id
  FROM public.clientes AS cl
  WHERE c.organization_id IS NULL
    AND c.cliente_id = cl.id;

  -- Hijos: siempre heredan la organización de la cabecera.
  UPDATE public.detalle_ventas AS d
  SET organization_id = v.organization_id
  FROM public.ventas AS v
  WHERE d.organization_id IS NULL
    AND d.venta_id = v.id;

  UPDATE public.pagos_venta AS p
  SET organization_id = v.organization_id
  FROM public.ventas AS v
  WHERE p.organization_id IS NULL
    AND p.venta_id = v.id;

  UPDATE public.detalle_cotizaciones AS d
  SET organization_id = c.organization_id
  FROM public.cotizaciones AS c
  WHERE d.organization_id IS NULL
    AND d.cotizacion_id = c.id;

  -- pagos_deuda_requests es polimórfica: empleado_id siempre existe y ya tiene tenant.
  UPDATE public.pagos_deuda_requests AS r
  SET organization_id = e.organization_id
  FROM public.empleados AS e
  WHERE r.organization_id IS NULL
    AND r.empleado_id = e.id;

  -- Requests anulados conservan snapshots; derivar desde actor/vendedor si existe.
  UPDATE public.ventas_requests_anulados AS r
  SET organization_id = e.organization_id
  FROM public.empleados AS e
  WHERE r.organization_id IS NULL
    AND r.anulada_por_empleado_id = e.id;

  UPDATE public.ventas_requests_anulados AS r
  SET organization_id = e.organization_id
  FROM public.empleados AS e
  WHERE r.organization_id IS NULL
    AND r.vendedor_id_original = e.id;

  SELECT
    EXISTS (SELECT 1 FROM public.ventas WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.cotizaciones WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.detalle_ventas WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.pagos_venta WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.detalle_cotizaciones WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.pagos_deuda_requests WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.ventas_requests_anulados WHERE organization_id IS NULL)
  INTO v_needs_fallback;

  IF v_needs_fallback THEN
    SELECT count(DISTINCT organization_id)::integer
    INTO v_organization_count
    FROM public.configuracion_negocio;

    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Ambiguous legacy state: unscoped sales data requires exactly one business organization';
    END IF;

    SELECT organization_id
    INTO v_fallback_organization_id
    FROM public.configuracion_negocio
    ORDER BY organization_id::text
    LIMIT 1;

    UPDATE public.ventas SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.cotizaciones SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.detalle_ventas SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.pagos_venta SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.detalle_cotizaciones SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.pagos_deuda_requests SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.ventas_requests_anulados SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
  END IF;

  -- Cabeceras no pueden apuntar a clientes/empleados de otra empresa.
  IF EXISTS (
    SELECT 1
    FROM public.ventas AS v
    JOIN public.clientes AS c ON c.id=v.cliente_id
    WHERE v.cliente_id IS NOT NULL
      AND v.organization_id IS DISTINCT FROM c.organization_id
  ) OR EXISTS (
    SELECT 1
    FROM public.ventas AS v
    JOIN public.empleados AS e ON e.id=v.vendedor_id
    WHERE v.vendedor_id IS NOT NULL
      AND v.organization_id IS DISTINCT FROM e.organization_id
  ) OR EXISTS (
    SELECT 1
    FROM public.ventas AS v
    JOIN public.empleados AS e ON e.id=v.descuento_autorizado_por
    WHERE v.descuento_autorizado_por IS NOT NULL
      AND v.organization_id IS DISTINCT FROM e.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant sale header relationship exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cotizaciones AS c
    JOIN public.clientes AS cl ON cl.id=c.cliente_id
    WHERE c.cliente_id IS NOT NULL
      AND c.organization_id IS DISTINCT FROM cl.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant quotation/customer relationship exists';
  END IF;

  -- Detalles deben coincidir simultáneamente con cabecera, producto y almacén.
  IF EXISTS (
    SELECT 1
    FROM public.detalle_ventas AS d
    LEFT JOIN public.ventas AS v ON v.id=d.venta_id
    LEFT JOIN public.productos AS p ON p.id=d.producto_id
    LEFT JOIN public.almacenes AS a ON a.id=d.almacen_id
    WHERE (v.id IS NOT NULL AND d.organization_id IS DISTINCT FROM v.organization_id)
       OR (p.id IS NOT NULL AND d.organization_id IS DISTINCT FROM p.organization_id)
       OR (a.id IS NOT NULL AND d.organization_id IS DISTINCT FROM a.organization_id)
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant sale detail relationship exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.detalle_cotizaciones AS d
    LEFT JOIN public.cotizaciones AS c ON c.id=d.cotizacion_id
    LEFT JOIN public.productos AS p ON p.id=d.producto_id
    LEFT JOIN public.almacenes AS a ON a.id=d.almacen_id
    WHERE (c.id IS NOT NULL AND d.organization_id IS DISTINCT FROM c.organization_id)
       OR (p.id IS NOT NULL AND d.organization_id IS DISTINCT FROM p.organization_id)
       OR (a.id IS NOT NULL AND d.organization_id IS DISTINCT FROM a.organization_id)
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant quotation detail relationship exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pagos_venta AS p
    JOIN public.ventas AS v ON v.id=p.venta_id
    WHERE p.organization_id IS DISTINCT FROM v.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant sale payment relationship exists';
  END IF;

  -- Para solicitudes de cobro a cliente, deuda_id debe ser una venta del mismo tenant.
  -- La rama de proveedor se completa en F3.6 cuando gastos reciba organization_id.
  IF EXISTS (
    SELECT 1
    FROM public.pagos_deuda_requests AS r
    JOIN public.ventas AS v ON r.es_cliente AND v.id=r.deuda_id
    WHERE r.organization_id IS DISTINCT FROM v.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant customer debt request exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pagos_deuda_requests AS r
    JOIN public.empleados AS e ON e.id=r.empleado_id
    WHERE r.organization_id IS DISTINCT FROM e.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant debt request actor exists';
  END IF;

  IF EXISTS (SELECT 1 FROM public.ventas WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.detalle_ventas WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.pagos_venta WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.cotizaciones WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.detalle_cotizaciones WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.pagos_deuda_requests WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.ventas_requests_anulados WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped sales rows remain after tenant backfill';
  END IF;
END;
$backfill$;

ALTER TABLE public.ventas ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.detalle_ventas ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.pagos_venta ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.cotizaciones ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.detalle_cotizaciones ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.pagos_deuda_requests ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.ventas_requests_anulados ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.ventas
  ADD CONSTRAINT ventas_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT ventas_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.detalle_ventas
  ADD CONSTRAINT detalle_ventas_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.pagos_venta
  ADD CONSTRAINT pagos_venta_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_venta_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.cotizaciones
  ADD CONSTRAINT cotizaciones_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT cotizaciones_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.detalle_cotizaciones
  ADD CONSTRAINT detalle_cotizaciones_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.pagos_deuda_requests
  ADD CONSTRAINT pagos_deuda_requests_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_deuda_requests_organization_request_key UNIQUE (organization_id,request_id);
ALTER TABLE public.ventas_requests_anulados
  ADD CONSTRAINT ventas_requests_anulados_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT ventas_requests_anulados_organization_request_key UNIQUE (organization_id,request_id);

CREATE INDEX ventas_organization_id_idx ON public.ventas(organization_id);
CREATE INDEX detalle_ventas_organization_id_idx ON public.detalle_ventas(organization_id);
CREATE INDEX pagos_venta_organization_id_idx ON public.pagos_venta(organization_id);
CREATE INDEX cotizaciones_organization_id_idx ON public.cotizaciones(organization_id);
CREATE INDEX detalle_cotizaciones_organization_id_idx ON public.detalle_cotizaciones(organization_id);
CREATE INDEX pagos_deuda_requests_organization_id_idx ON public.pagos_deuda_requests(organization_id);
CREATE INDEX ventas_requests_anulados_organization_id_idx ON public.ventas_requests_anulados(organization_id);

-- FKs tenant-qualified. Se preservan los nombres usados por PostgREST/Flutter.
ALTER TABLE public.ventas
  DROP CONSTRAINT IF EXISTS ventas_cliente_id_fkey,
  DROP CONSTRAINT IF EXISTS ventas_vendedor_id_fkey,
  DROP CONSTRAINT IF EXISTS ventas_descuento_autorizado_por_fkey;
ALTER TABLE public.ventas
  ADD CONSTRAINT ventas_cliente_id_fkey
    FOREIGN KEY (organization_id,cliente_id) REFERENCES public.clientes(organization_id,id) ON DELETE SET NULL (cliente_id),
  ADD CONSTRAINT ventas_vendedor_id_fkey
    FOREIGN KEY (organization_id,vendedor_id) REFERENCES public.empleados(organization_id,id),
  ADD CONSTRAINT ventas_descuento_autorizado_por_fkey
    FOREIGN KEY (organization_id,descuento_autorizado_por) REFERENCES public.empleados(organization_id,id) ON DELETE SET NULL (descuento_autorizado_por);

ALTER TABLE public.detalle_ventas
  DROP CONSTRAINT IF EXISTS detalle_ventas_venta_id_fkey,
  DROP CONSTRAINT IF EXISTS detalle_ventas_producto_id_fkey,
  DROP CONSTRAINT IF EXISTS detalle_ventas_almacen_id_fkey;
ALTER TABLE public.detalle_ventas
  ADD CONSTRAINT detalle_ventas_venta_id_fkey
    FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT detalle_ventas_producto_id_fkey
    FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT detalle_ventas_almacen_id_fkey
    FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.pagos_venta
  DROP CONSTRAINT IF EXISTS pagos_venta_venta_id_fkey,
  DROP CONSTRAINT IF EXISTS pagos_venta_request_id_fkey;
ALTER TABLE public.pagos_venta
  ADD CONSTRAINT pagos_venta_venta_id_fkey
    FOREIGN KEY (organization_id,venta_id) REFERENCES public.ventas(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT pagos_venta_request_id_fkey
    FOREIGN KEY (organization_id,request_id) REFERENCES public.pagos_deuda_requests(organization_id,request_id) ON DELETE RESTRICT;

ALTER TABLE public.cotizaciones DROP CONSTRAINT IF EXISTS cotizaciones_cliente_id_fkey;
ALTER TABLE public.cotizaciones
  ADD CONSTRAINT cotizaciones_cliente_id_fkey
    FOREIGN KEY (organization_id,cliente_id) REFERENCES public.clientes(organization_id,id);

ALTER TABLE public.detalle_cotizaciones
  DROP CONSTRAINT IF EXISTS detalle_cotizaciones_cotizacion_id_fkey,
  DROP CONSTRAINT IF EXISTS detalle_cotizaciones_producto_id_fkey,
  DROP CONSTRAINT IF EXISTS detalle_cotizaciones_almacen_id_fkey;
ALTER TABLE public.detalle_cotizaciones
  ADD CONSTRAINT detalle_cotizaciones_cotizacion_id_fkey
    FOREIGN KEY (organization_id,cotizacion_id) REFERENCES public.cotizaciones(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT detalle_cotizaciones_producto_id_fkey
    FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT detalle_cotizaciones_almacen_id_fkey
    FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.pagos_deuda_requests DROP CONSTRAINT IF EXISTS pagos_deuda_requests_empleado_id_fkey;
ALTER TABLE public.pagos_deuda_requests
  ADD CONSTRAINT pagos_deuda_requests_empleado_id_fkey
    FOREIGN KEY (organization_id,empleado_id) REFERENCES public.empleados(organization_id,id);

-- Tenant asignado server-side e inmutable. Las FKs compuestas son la segunda barrera.
CREATE TRIGGER ventas_enforce_organization_id BEFORE INSERT OR UPDATE ON public.ventas FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER detalle_ventas_enforce_organization_id BEFORE INSERT OR UPDATE ON public.detalle_ventas FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER pagos_venta_enforce_organization_id BEFORE INSERT OR UPDATE ON public.pagos_venta FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER cotizaciones_enforce_organization_id BEFORE INSERT OR UPDATE ON public.cotizaciones FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER detalle_cotizaciones_enforce_organization_id BEFORE INSERT OR UPDATE ON public.detalle_cotizaciones FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER pagos_deuda_requests_enforce_organization_id BEFORE INSERT OR UPDATE ON public.pagos_deuda_requests FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER ventas_requests_anulados_enforce_organization_id BEFORE INSERT OR UPDATE ON public.ventas_requests_anulados FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();

-- RLS: dominio comercial es de lectura directa; mutaciones complejas sólo por RPC.
ALTER TABLE public.ventas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.detalle_ventas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos_venta ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cotizaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.detalle_cotizaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos_deuda_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventas_requests_anulados ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ventas_select ON public.ventas;
DROP POLICY IF EXISTS detalle_ventas_select ON public.detalle_ventas;
DROP POLICY IF EXISTS pagos_venta_select ON public.pagos_venta;
DROP POLICY IF EXISTS cotizaciones_select_empleado ON public.cotizaciones;
DROP POLICY IF EXISTS detalle_cotizaciones_select_empleado ON public.detalle_cotizaciones;
DROP POLICY IF EXISTS ventas_anuladas_admin ON public.ventas_requests_anulados;

CREATE POLICY ventas_tenant_select ON public.ventas
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY detalle_ventas_tenant_select ON public.detalle_ventas
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY pagos_venta_tenant_select ON public.pagos_venta
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY cotizaciones_tenant_select ON public.cotizaciones
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY detalle_cotizaciones_tenant_select ON public.detalle_cotizaciones
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY ventas_requests_anulados_tenant_select ON public.ventas_requests_anulados
FOR SELECT TO authenticated
USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));

REVOKE ALL ON TABLE public.ventas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.detalle_ventas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.pagos_venta FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.cotizaciones FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.detalle_cotizaciones FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.pagos_deuda_requests FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.ventas_requests_anulados FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.ventas TO authenticated;
GRANT SELECT ON TABLE public.detalle_ventas TO authenticated;
GRANT SELECT ON TABLE public.pagos_venta TO authenticated;
GRANT SELECT ON TABLE public.cotizaciones TO authenticated;
GRANT SELECT ON TABLE public.detalle_cotizaciones TO authenticated;
GRANT SELECT ON TABLE public.ventas_requests_anulados TO authenticated;

COMMIT;
