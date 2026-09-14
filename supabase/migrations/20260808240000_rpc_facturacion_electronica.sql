-- ----------------------------------------------------------------------------
-- RPCs de facturación electrónica y procesos tributarios
-- ----------------------------------------------------------------------------
-- Este archivo agrupa las definiciones fuente que viven en supabase/migrations/RPCs.
-- Se usa \\ir para mantener una sola fuente de verdad por RPC y permitir despliegue
-- directo con Supabase CLI / psql.

\ir RPCs/facturacion_claim_comprobante.sql
\ir RPCs/facturacion_finalizar_comprobante.sql
\ir RPCs/nota_credito_claim.sql
\ir RPCs/nota_credito_finalizar.sql
\ir RPCs/gre_claim_v2.sql
\ir RPCs/gre_finalizar.sql
\ir RPCs/listar_documentos_electronicos_v1.sql
\ir RPCs/resolver_resultado_incierto_v1.sql
\ir RPCs/solicitar_baja_tributaria_v1.sql
\ir RPCs/tributario_claim_proceso.sql
\ir RPCs/tributario_finalizar_proceso.sql
