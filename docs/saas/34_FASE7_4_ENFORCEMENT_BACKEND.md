# Fase 7.4 — Enforcement backend

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908056100_saas_plan_entitlements_expiry_feature.sql`
- `supabase/migrations/20260908057000_saas_subscription_backend_enforcement.sql`
- `supabase/migrations/20260908057100_saas_subscription_analytics_assistant_enforcement.sql`
- `supabase/migrations/20260908057200_saas_subscription_change_audit.sql`

Gate:

- `scripts/verify_saas_subscription_enforcement.mjs`

pgTAP:

- `supabase/tests/database/subscription_enforcement_contract_test.sql` — 30 assertions.

## Enforcement

El backend aplica el plan en cuatro niveles:

1. `business_capabilities` no puede habilitar features que el plan no permita;
2. altas/reactivaciones de usuarios, sucursales, almacenes y cajas respetan límites del plan;
3. un downgrade de plan se rechaza si las capabilities o el uso actual exceden el nuevo plan;
4. modificar el packaging de un plan se rechaza si dejaría incompatible a cualquier tenant activo/trialing ya asignado.

## Features fuera de business_capabilities

`feature.analytics` protege server-side:

- `get_configurable_dashboard_v1`;
- `list_business_metrics_v1`;
- `save_business_metrics_v1`.

`feature.business_assistant` protege:

- `get_business_assistant_context_v1`;
- habilitar `business_assistant_settings`.

Los patches son deterministas: si cambia la definición upstream esperada, la migración aborta en vez de aplicar un hardening parcial.

## Límites

Se aplican a:

- `limit.users` -> `app_users.status='active'`;
- `limit.branches` -> `branches.status='active'`;
- `limit.warehouses` -> `almacenes.activo`;
- `limit.cash_registers` -> `cash_registers.status='active'`.

`NULL` significa sin límite configurado. El seed neutral F7.3 conserva compatibilidad hasta que exista packaging comercial explícito.

## Auditoría

Cambios de plan/estado/periodo generan `subscription.updated` en `audit_logs`, con metadata allowlisted.

## Validación pendiente

T02/T03/T04/T07/T09/T12/T14/T17 deben probar límites, downgrade, suspensión y aislamiento entre ORG_A/ORG_B. Gate Bloque 7 permanece abierto.
