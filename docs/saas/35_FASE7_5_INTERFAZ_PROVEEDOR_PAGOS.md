# Fase 7.5 — Interfaz para proveedor de pagos

## Estado

**IMPLEMENTADA COMO INTERFAZ AGNÓSTICA / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908058000_saas_billing_provider_interface.sql`
- `supabase/migrations/20260908058100_saas_billing_edge_rpc_surface.sql`

Edge contract:

- `supabase/functions/_shared/billing_provider_contract.ts`

Core Logic:

- `billing/domain/billing_summary.dart`
- `billing/application/billing_summary_gateway.dart`
- `billing/data/supabase_billing_summary_gateway.dart`
- `billing/providers/billing_summary_providers.dart`

Gate:

- `scripts/verify_saas_billing_provider_interface.mjs`

pgTAP:

- `supabase/tests/database/billing_provider_interface_contract_test.sql` — 28 assertions.

## Diseño

F7.5 no selecciona ni integra todavía Stripe, Mercado Pago, Paddle, PayPal u otro proveedor. Define una interfaz verificable para conectar uno posteriormente.

### Mappings de precio

`billing_provider_plan_prices` resuelve:

`(provider_code, external_price_ref) -> subscription_plan`

El webhook **no entrega `plan_code` como autoridad**. Si el price externo no tiene mapping activo, el evento falla cerrado.

### Cuenta externa por tenant

`billing_provider_accounts` mantiene referencias externas privadas por organización. Ningún cliente autenticado recibe customer/subscription refs.

### Ledger de webhook

`billing_webhook_events` guarda sólo:

- provider;
- event ID;
- event type;
- SHA-256 del payload;
- organization resuelta;
- estado `received/processed/failed`;
- timestamps;
- `error_code` acotado.

No almacena payload/body bruto.

La PK `(provider_code,event_id)` hace la ingestión idempotente. Un duplicado no vuelve a cambiar la suscripción.

### Procesamiento

`private.apply_billing_subscription_event_v1`:

1. exige contexto `service_role/postgres`;
2. registra/deduplica el evento;
3. resuelve organización por external subscription ref;
4. resuelve plan por external price mapping;
5. llama al writer F7.2 con `assignment_reason='billing_sync'`;
6. conserva resultado processed/failed.

El wrapper público `apply_billing_subscription_event_v1` tiene EXECUTE únicamente para `service_role`, permitiendo uso desde una Edge Function después de que el adaptador concreto verifique la firma del proveedor.

## Contrato Edge

`BillingProviderAdapter.verifyAndNormalize(Request)` obliga al adaptador concreto a verificar autenticidad antes de producir un `NormalizedBillingSubscriptionEvent`.

El evento normalizado no incluye `organization_id` ni `plan_code`.

## App

`get_my_billing_summary_v1()` expone sólo datos saneados de la suscripción y si existe una cuenta de proveedor vinculada. No expone IDs externos ni eventos.

## Validación pendiente

T02/T03/T04/T07/T09/T10/T13/T14/T17. La integración real de un proveedor concreto requerirá sus propias pruebas de firma/webhook antes de salida comercial.
