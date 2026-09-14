# Fase 7.3 — Entitlements y límites

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migración:

- `supabase/migrations/20260908056000_saas_plan_entitlements_limits.sql`

Core Logic:

- `billing/domain/subscription_entitlement.dart`
- `billing/application/subscription_entitlement_gateway.dart`
- `billing/data/supabase_subscription_entitlement_gateway.dart`
- `billing/providers/subscription_entitlement_providers.dart`

Gate:

- `scripts/verify_saas_plan_entitlements.mjs`

pgTAP:

- `supabase/tests/database/plan_entitlements_contract_test.sql` — 24 assertions.

## Contrato

- Catálogo global cerrado de entitlements tipados `feature` / `limit`.
- Features iniciales cubren inventario, multisucursal/multialmacén, crédito, fiscal, compras, servicios, variantes, trazabilidad, analítica y asistente.
- Límites iniciales cubren usuarios, sucursales, almacenes y cajas.
- `get_my_entitlements_v1()` deriva la suscripción desde el tenant autenticado.
- Helpers privados `subscription_feature_enabled` / `subscription_limit_value` preparan F7.4.
- Configuración de plan sólo mediante writer `service_role/postgres`.

## Packaging comercial

El seed inicial es deliberadamente neutral: features habilitadas y límites `NULL` (sin límite configurado). El repositorio no contenía decisiones comerciales verificadas como número de usuarios por plan, por lo que F7.3 no inventa esas cifras. El esquema permite configurarlas posteriormente sin migración.

## Validación pendiente

T02/T03/T04/T07/T09/T13/T14/T17. Gate Bloque 7 permanece abierto.
