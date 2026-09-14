# Fase 7.2 — Suscripción por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

## Implementación

Migración:

- `supabase/migrations/20260908055000_saas_organization_subscriptions.sql`

Core Logic:

- `billing/domain/organization_subscription.dart`
- `billing/application/organization_subscription_gateway.dart`
- `billing/data/supabase_organization_subscription_gateway.dart`
- `billing/providers/organization_subscription_providers.dart`

Gate:

- `scripts/verify_saas_organization_subscriptions.mjs`

pgTAP:

- `supabase/tests/database/organization_subscriptions_contract_test.sql` — 20 assertions.

## Contrato

- Una fila de `organization_subscriptions` por `organization_id`.
- Plan enlazado al catálogo global F7.1.
- Estados permitidos: `trialing`, `active`, `past_due`, `suspended`, `canceled`.
- Lectura tenant-aware mediante `get_my_subscription_v1()`.
- El cliente no puede insertar/actualizar/eliminar suscripciones directamente.
- El writer `private.set_organization_subscription_v1(...)` es sólo `service_role/postgres` y usa optimistic concurrency por `revision`.

## Rollout compatible

Para no romper funcionalidades antes de F7.3/F7.4, organizaciones existentes y nuevas reciben temporalmente el plan `enterprise` activo. Esto es una decisión de migración, no una política comercial definitiva. F8 permitirá seleccionar/configurar el plan durante onboarding y F7.5 sincronizará la facturación real.

## Validación pendiente

T02/T03/T04/T07/T09/T13/T14/T17. El Gate Bloque 7 permanece abierto.
