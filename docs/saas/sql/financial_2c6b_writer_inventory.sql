-- 2C6B prerequisite: read-only inventory of financial/fiscal entrypoints.
-- Inspect full definitions and nested writers before changing lock order.
-- Definition fingerprints detect drift; they do not prove concurrency safety.
SELECT n.nspname AS schema_name,p.proname,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       md5(pg_get_functiondef(p.oid)) AS definition_md5,
       p.prosecdef AS security_definer,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_execute,
       pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private') AND p.proname IN (
 'financial_2c2_record_transfer_payment','financial_2c3b_record_cash_payment',
 'financial_2c5a_reverse_transfer_payment','financial_2c5b_open_refund_case',
 'financial_2b_guard_legacy_financial_write','financial_2c_audit_sale',
 'nota_credito_finalizar','tributario_finalizar_proceso',
 'recalcular_estado_tributario_venta','_aplicar_stock_nota_credito',
 '_revertir_stock_nota_credito_por_baja','procesar_pago_deuda_v2')
ORDER BY n.nspname,p.proname,arguments;
