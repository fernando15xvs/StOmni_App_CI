-- Cierra RPCs internas SECURITY DEFINER que solo deben ser usadas
-- por funciones SQL internas o Edge Functions con service_role.
DO $do$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        '_aplicar_movimiento_inventario_v2',
        '_aplicar_stock_nota_credito',
        '_revertir_stock_nota_credito_por_baja',
        'facturacion_claim_comprobante',
        'facturacion_finalizar_comprobante',
        'gre_claim',
        'gre_claim_v2',
        'gre_finalizar',
        'nota_credito_claim',
        'nota_credito_finalizar',
        'recalcular_estado_tributario_venta',
        'resolver_resultado_incierto_v1',
        'tributario_claim_proceso',
        'tributario_finalizar_proceso',
        'tributario_preparar_procesos',
        'tributario_reintentar_stock_bajas'
      ]::text[])
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated',
      r.signature
    );
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %s TO service_role',
      r.signature
    );
  END LOOP;
END
$do$;
