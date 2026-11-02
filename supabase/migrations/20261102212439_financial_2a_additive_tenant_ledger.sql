-- Fase 2A: esquema aditivo, sin activar ventas/cobros ni migrar saldos heredados.
CREATE UNIQUE INDEX IF NOT EXISTS pagos_venta_org_sale_id_fin2a_uix
    ON public.pagos_venta (organization_id, venta_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS notas_credito_org_sale_id_fin2a_uix
    ON public.notas_credito (organization_id, venta_id, id);

CREATE TABLE public.venta_cuentas_financieras (
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
    venta_id bigint NOT NULL,
    moneda text NOT NULL CHECK (moneda ~ '^[A-Z]{3}$'),
    version_motor integer NOT NULL DEFAULT 1 CHECK (version_motor > 0),
    estado_conciliacion text NOT NULL DEFAULT 'pendiente'
        CHECK (estado_conciliacion IN ('pendiente', 'conciliada', 'bloqueada')),
    exigible numeric(14,2) NOT NULL DEFAULT 0 CHECK (exigible >= 0),
    cobros_netos numeric(14,2) NOT NULL DEFAULT 0 CHECK (cobros_netos >= 0),
    saldo_pendiente numeric(14,2) NOT NULL DEFAULT 0 CHECK (saldo_pendiente >= 0),
    excedente numeric(14,2) NOT NULL DEFAULT 0 CHECK (excedente >= 0),
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
    creado_at timestamptz NOT NULL DEFAULT now(),
    actualizado_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT venta_cuentas_financieras_pkey PRIMARY KEY (organization_id, venta_id),
    CONSTRAINT venta_cuentas_venta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.ventas(organization_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_cuentas_igualdad_check CHECK (exigible + excedente = cobros_netos + saldo_pendiente),
    CONSTRAINT venta_cuentas_no_dual_check CHECK (saldo_pendiente = 0 OR excedente = 0)
);

CREATE TABLE public.venta_operaciones_financieras (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    venta_id bigint NOT NULL,
    tipo text NOT NULL CHECK (tipo IN ('apertura', 'cobro', 'reverso', 'devolucion', 'nota_credito', 'nota_debito', 'cancelacion', 'reversion_ajuste')),
    request_id uuid NOT NULL,
    actor_id uuid,
    payload_hash text NOT NULL CHECK (length(btrim(payload_hash)) > 0),
    resultado text NOT NULL DEFAULT 'pendiente' CHECK (resultado IN ('pendiente', 'aplicado', 'rechazado')),
    creado_at timestamptz NOT NULL DEFAULT now(),
    actualizado_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT venta_ops_org_sale_id_unique UNIQUE (organization_id, venta_id, id),
    CONSTRAINT venta_ops_request_unique UNIQUE (organization_id, tipo, request_id),
    CONSTRAINT venta_ops_cuenta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.venta_cuentas_financieras(organization_id, venta_id) ON DELETE RESTRICT
);

CREATE TABLE public.venta_eventos_financieros (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    venta_id bigint NOT NULL,
    operacion_id uuid NOT NULL,
    secuencia bigint NOT NULL CHECK (secuencia > 0),
    tipo text NOT NULL CHECK (tipo IN ('apertura', 'cobro', 'reverso', 'devolucion', 'nota_credito', 'nota_debito', 'cancelacion', 'reversion_ajuste')),
    delta_exigible numeric(14,2) NOT NULL DEFAULT 0,
    delta_cobros numeric(14,2) NOT NULL DEFAULT 0,
    efectivo_at timestamptz NOT NULL,
    registrado_at timestamptz NOT NULL DEFAULT now(),
    reversa_evento_id uuid,
    pago_id bigint,
    nota_credito_id uuid,
    CONSTRAINT venta_eventos_org_sale_id_unique UNIQUE (organization_id, venta_id, id),
    CONSTRAINT venta_eventos_secuencia_unique UNIQUE (organization_id, venta_id, secuencia),
    CONSTRAINT venta_eventos_cuenta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.venta_cuentas_financieras(organization_id, venta_id) ON DELETE RESTRICT,
    CONSTRAINT venta_eventos_op_fkey FOREIGN KEY (organization_id, venta_id, operacion_id)
        REFERENCES public.venta_operaciones_financieras(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_eventos_reversa_fkey FOREIGN KEY (organization_id, venta_id, reversa_evento_id)
        REFERENCES public.venta_eventos_financieros(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_eventos_pago_fkey FOREIGN KEY (organization_id, venta_id, pago_id)
        REFERENCES public.pagos_venta(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_eventos_nc_fkey FOREIGN KEY (organization_id, venta_id, nota_credito_id)
        REFERENCES public.notas_credito(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_eventos_origen_check CHECK (pago_id IS NULL OR nota_credito_id IS NULL),
    CONSTRAINT venta_eventos_delta_check CHECK (delta_exigible <> 0 OR delta_cobros <> 0)
);

CREATE TABLE public.venta_cronogramas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    venta_id bigint NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    estado text NOT NULL CHECK (estado IN ('vigente', 'sustituido', 'cancelado')),
    origen_evento_id uuid,
    creado_por uuid,
    creado_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT venta_cronos_org_sale_id_unique UNIQUE (organization_id, venta_id, id),
    CONSTRAINT venta_cronos_version_unique UNIQUE (organization_id, venta_id, version),
    CONSTRAINT venta_cronos_cuenta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.venta_cuentas_financieras(organization_id, venta_id) ON DELETE RESTRICT,
    CONSTRAINT venta_cronos_evento_fkey FOREIGN KEY (organization_id, venta_id, origen_evento_id)
        REFERENCES public.venta_eventos_financieros(organization_id, venta_id, id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX venta_cronos_vigente_fin2a_uix
    ON public.venta_cronogramas(organization_id, venta_id) WHERE estado = 'vigente';

CREATE TABLE public.venta_cuotas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    venta_id bigint NOT NULL,
    cronograma_id uuid NOT NULL,
    numero integer NOT NULL CHECK (numero > 0),
    obligacion_id uuid NOT NULL DEFAULT gen_random_uuid(),
    vencimiento date,
    es_legado boolean NOT NULL DEFAULT false,
    importe_original numeric(14,2) NOT NULL CHECK (importe_original > 0),
    importe_vigente numeric(14,2) NOT NULL CHECK (importe_vigente >= 0),
    creado_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT venta_cuotas_org_sale_id_unique UNIQUE (organization_id, venta_id, id),
    CONSTRAINT venta_cuotas_numero_unique UNIQUE (organization_id, cronograma_id, numero),
    CONSTRAINT venta_cuotas_vencimiento_check CHECK (es_legado OR vencimiento IS NOT NULL),
    CONSTRAINT venta_cuotas_cuenta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.venta_cuentas_financieras(organization_id, venta_id) ON DELETE RESTRICT,
    CONSTRAINT venta_cuotas_crono_fkey FOREIGN KEY (organization_id, venta_id, cronograma_id)
        REFERENCES public.venta_cronogramas(organization_id, venta_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.venta_cuota_movimientos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    venta_id bigint NOT NULL,
    cuota_id uuid NOT NULL,
    evento_id uuid NOT NULL,
    tipo text NOT NULL CHECK (tipo IN ('cobro', 'liberacion_nc', 'reverso', 'transferencia', 'ajuste')),
    importe_asignado numeric(14,2) NOT NULL CHECK (importe_asignado <> 0),
    reversa_movimiento_id uuid,
    creado_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT venta_cuota_mov_org_sale_id_unique UNIQUE (organization_id, venta_id, id),
    CONSTRAINT venta_cuota_mov_cuenta_fkey FOREIGN KEY (organization_id, venta_id)
        REFERENCES public.venta_cuentas_financieras(organization_id, venta_id) ON DELETE RESTRICT,
    CONSTRAINT venta_cuota_mov_cuota_fkey FOREIGN KEY (organization_id, venta_id, cuota_id)
        REFERENCES public.venta_cuotas(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_cuota_mov_evento_fkey FOREIGN KEY (organization_id, venta_id, evento_id)
        REFERENCES public.venta_eventos_financieros(organization_id, venta_id, id) ON DELETE RESTRICT,
    CONSTRAINT venta_cuota_mov_reversa_fkey FOREIGN KEY (organization_id, venta_id, reversa_movimiento_id)
        REFERENCES public.venta_cuota_movimientos(organization_id, venta_id, id) ON DELETE RESTRICT
);

CREATE INDEX venta_cuentas_estado_fin2a_idx
    ON public.venta_cuentas_financieras(organization_id, estado_conciliacion);
CREATE INDEX venta_eventos_efectivo_fin2a_idx
    ON public.venta_eventos_financieros(organization_id, venta_id, efectivo_at);
CREATE INDEX venta_cuotas_vencimiento_fin2a_idx
    ON public.venta_cuotas(organization_id, vencimiento, venta_id);
CREATE INDEX venta_cuota_mov_asignacion_fin2a_idx
    ON public.venta_cuota_movimientos(organization_id, cuota_id, evento_id);

-- Ajustes históricos siempre mediante entradas compensatorias, nunca UPDATE/DELETE.
CREATE OR REPLACE FUNCTION private.saas_financial_2a_reject_history_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
BEGIN
    RAISE EXCEPTION 'El historial financiero es inmutable: registre un evento compensatorio'
        USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION private.saas_financial_2a_reject_history_mutation() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER venta_eventos_fin2a_immutable
    BEFORE UPDATE OR DELETE ON public.venta_eventos_financieros
    FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();
CREATE TRIGGER venta_cuota_mov_fin2a_immutable
    BEFORE UPDATE OR DELETE ON public.venta_cuota_movimientos
    FOR EACH ROW EXECUTE FUNCTION private.saas_financial_2a_reject_history_mutation();

-- Clientes: SELECT sólo con tenant.read + pertenencia; DML reservado al servidor.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'venta_cuentas_financieras',
        'venta_operaciones_financieras',
        'venta_eventos_financieros',
        'venta_cronogramas',
        'venta_cuotas',
        'venta_cuota_movimientos'
    ] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
        EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', t);
        EXECUTE format('GRANT ALL ON TABLE public.%I TO service_role', t);
        EXECUTE format(
            'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (private.has_permission(''tenant.read'') AND private.row_belongs_to_current_organization(organization_id))',
            t || '_tenant_select', t
        );
    END LOOP;
END;
$$;

COMMENT ON TABLE public.venta_cuentas_financieras IS
    'Fase 2A: proyeccion financiera sin motor activo; no usar como saldo canonico hasta 2B/2C.';
COMMENT ON TABLE public.venta_eventos_financieros IS
    'Fase 2A: historial inmutable, tenant y venta, sin backfill.';
COMMENT ON TABLE public.venta_cuotas IS
    'Fase 2A: cuotas versionadas; vencimiento nulo solo para legado.';

