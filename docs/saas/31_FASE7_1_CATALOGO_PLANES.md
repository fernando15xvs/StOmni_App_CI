# Fase 7.1 — Catálogo de planes

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

## Implementación

Migración:

- `supabase/migrations/20260908054000_saas_subscription_plan_catalog.sql`

Contrato `core_logic`:

- `billing/domain/subscription_plan.dart`
- `billing/application/subscription_plan_gateway.dart`
- `billing/data/supabase_subscription_plan_gateway.dart`
- `billing/providers/subscription_plan_providers.dart`

Gate:

- `scripts/verify_saas_subscription_plans.mjs`

pgTAP:

- `supabase/tests/database/subscription_plan_catalog_contract_test.sql` — 18 assertions.

## Decisiones

- `subscription_plans` es catálogo **global**, no tenant-owned.
- El cliente autenticado sólo puede leer planes `active + is_public`.
- No existe escritura Data API desde tenants.
- Códigos estables sembrados: `starter`, `business`, `pro`, `enterprise`.
- F7.1 no fija precios comerciales ni IDs de Stripe/Paddle/Mercado Pago/otro proveedor.
- Precios/provider IDs pertenecen a F7.5 y quedan desacoplados de la identidad del plan.

## Seguridad

- RLS habilitada.
- `INSERT/UPDATE/DELETE` revocados a `authenticated`.
- `list_subscription_plans_v1()` es la superficie de lectura para `core_logic`.
- El gate RPC global incorpora el gate F7.1.

## Validación pendiente

La validación dinámica queda en T02/T03/T04/T09/T13/T14/T17. No se marca el Gate Bloque 7 hasta completar F7.1–F7.5 y ejecutar las pruebas locales finales.
