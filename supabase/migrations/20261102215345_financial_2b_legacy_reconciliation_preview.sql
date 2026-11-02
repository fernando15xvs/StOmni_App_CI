-- Fase 2B (bloque 1): preconciliación conservadora y exclusivamente de lectura.
-- NO registra eventos, NO crea cuentas ni altera cobros, deudas o documentos.
-- Disponible sólo al administrador DB; no se publica como RPC de clientes.
CREATE FUNCTION private.financial_2b_preview_sales(
    p_organization_id uuid,
    p_limit integer DEFAULT 500
)
RETURNS TABLE (
    organization_id uuid,
    venta_id bigint,
    moneda text,
    total_venta numeric,
    cobros_registrados numeric,
    notas_credito_declaradas numeric,
    saldo_guardado numeric,
    saldo_estimado numeric,
    estado_preconciliacion text,
    motivos text[]
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $fn$
    WITH base AS (
        SELECT
            v.organization_id,
            v.id AS venta_id,
            o.currency_code AS moneda,
            v.total AS total_venta,
            COALESCE(p.cobros, 0::numeric) AS cobros_registrados,
            v.monto_notas_credito AS notas_credito_declaradas,
            v.saldo AS saldo_guardado,
            v.total - COALESCE(p.cobros, 0::numeric) AS saldo_estimado,
            v.fecha AS fecha_venta,
            v.estado AS estado_venta,
            COALESCE(p.pagos_validos, true) AS pagos_validos,
            COALESCE(n.notas, 0::bigint) AS notas,
            COALESCE(d.monedas_consistentes, true) AS monedas_consistentes,
            cf.venta_id IS NOT NULL AS cuenta_existente
        FROM public.ventas AS v
        JOIN public.organizations AS o ON o.id = v.organization_id
        LEFT JOIN public.venta_cuentas_financieras AS cf
            ON cf.organization_id = v.organization_id AND cf.venta_id = v.id
        LEFT JOIN LATERAL (
            SELECT
                SUM(pv.monto) AS cobros,
                BOOL_AND(
                    pv.monto > 0 AND pv.monto = ROUND(pv.monto, 2)
                    AND pv.monto <= 999999999999.99
                    AND pv.fecha IS NOT NULL
                    AND LENGTH(BTRIM(pv.metodo)) > 0
                ) AS pagos_validos
            FROM public.pagos_venta AS pv
            WHERE pv.organization_id = v.organization_id AND pv.venta_id = v.id
        ) AS p ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(*) AS notas
            FROM public.notas_credito AS nc
            WHERE nc.organization_id = v.organization_id AND nc.venta_id = v.id
        ) AS n ON true
        LEFT JOIN LATERAL (
            SELECT BOOL_AND(ce.moneda = o.currency_code) AS monedas_consistentes
            FROM public.comprobantes_electronicos AS ce
            WHERE ce.organization_id = v.organization_id AND ce.venta_id = v.id
        ) AS d ON true
        WHERE v.organization_id = p_organization_id
        ORDER BY v.id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 0), 0), 1000)
    ),
    checks AS (
        SELECT b.*,
            ARRAY_REMOVE(ARRAY[
                CASE WHEN b.cuenta_existente THEN 'cuenta_ya_abierta' END,
                CASE WHEN b.moneda IS NULL OR b.moneda !~ '^[A-Z]{3}$'
                    THEN 'moneda_organizacion_invalida' END,
                CASE WHEN NOT b.monedas_consistentes
                    THEN 'moneda_comprobante_distinta' END,
                CASE WHEN b.fecha_venta IS NULL
                    THEN 'fecha_venta_ausente' END,
                CASE WHEN b.estado_venta IS NULL
                         OR LOWER(BTRIM(b.estado_venta)) IN ('anulado','anulada','cancelado','cancelada')
                    THEN 'estado_venta_no_conciliable' END,
                CASE WHEN b.total_venta IS NULL OR b.total_venta <= 0
                         OR b.total_venta <> ROUND(b.total_venta, 2)
                         OR b.total_venta > 999999999999.99
                    THEN 'total_fuera_contrato_monetario' END,
                CASE WHEN b.notas_credito_declaradas IS NULL
                         OR b.notas_credito_declaradas <> 0 OR b.notas > 0
                    THEN 'ajustes_nc_requieren_conciliacion_individual' END,
                CASE WHEN NOT b.pagos_validos
                    THEN 'pagos_incompletos_o_invalidos' END,
                CASE WHEN b.cobros_registrados < 0
                         OR b.cobros_registrados > b.total_venta
                    THEN 'pagos_fuera_del_exigible' END,
                CASE WHEN b.saldo_guardado IS NULL
                         OR b.saldo_guardado < 0
                         OR b.saldo_guardado <> ROUND(b.saldo_guardado, 2)
                         OR b.saldo_guardado <> b.saldo_estimado
                    THEN 'saldo_legacy_no_cuadra' END
            ]::text[], NULL::text) AS razones
        FROM base AS b
    )
    SELECT
        c.organization_id,
        c.venta_id,
        c.moneda,
        c.total_venta,
        c.cobros_registrados,
        c.notas_credito_declaradas,
        c.saldo_guardado,
        c.saldo_estimado,
        CASE WHEN CARDINALITY(c.razones) = 0 THEN 'lista'
             ELSE 'bloqueada' END AS estado_preconciliacion,
        c.razones AS motivos
    FROM checks AS c
    ORDER BY c.venta_id;
$fn$;

-- PostgreSQL concede EXECUTE a PUBLIC de forma predeterminada: cerrar esa vía.
REVOKE ALL ON FUNCTION private.financial_2b_preview_sales(uuid, integer)
    FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION private.financial_2b_preview_sales(uuid, integer) IS
    'Diagnóstico administrativo 2B read-only. Lista no autoriza apertura automática: requiere corte transaccional y escritores protegidos en 2C.';
