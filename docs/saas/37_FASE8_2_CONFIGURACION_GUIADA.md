# Fase 8.2 — Configuración guiada

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migración:

- `supabase/migrations/20260908059100_saas_guided_onboarding_progress.sql`

Core Logic:

- `onboarding/domain/guided_onboarding.dart`
- `onboarding/application/guided_onboarding_gateway.dart`
- `onboarding/application/guided_onboarding_use_case.dart`
- `onboarding/data/supabase_guided_onboarding_gateway.dart`
- `onboarding/providers/guided_onboarding_providers.dart`

Gate:

- `scripts/verify_saas_guided_onboarding.mjs`

pgTAP:

- `supabase/tests/database/guided_onboarding_contract_test.sql` — 22 assertions.

## Diseño

F8.2 no crea una segunda fuente de configuración. `organization_onboarding_progress` guarda únicamente estado de workflow:

- `organization_id`;
- `status`;
- pasos reconocidos;
- `revision`;
- timestamps.

Los datos reales siguen en sus dominios autoritativos.

## Pasos V1

El flujo cerrado es:

1. `business_profile`;
2. `modules`;
3. `operations`;
4. `review`.

El backend no permite saltar pasos. Cada mutación exige `tenant.admin` y optimistic concurrency mediante `revision`.

## Validación contra fuentes autoritativas

Antes de aceptar un paso, PostgreSQL comprueba:

- `business_profile` -> existe `configuracion_negocio` del tenant;
- `modules` -> existe `business_capabilities` del tenant;
- `operations` -> existe sucursal principal activa y caja por defecto activa;
- `review` -> los tres pasos anteriores ya fueron reconocidos.

Así el progreso no sustituye la configuración real.

## Compatibilidad con tenants existentes

Las organizaciones existentes cuando se aplica F8.2 se backfillean como `completed` para no obligarlas a repetir onboarding.

Las organizaciones creadas después reciben automáticamente una fila `in_progress` mediante trigger de `organizations`.

## Seguridad

- RLS por `organization_id`;
- lectura sólo del tenant actual;
- escritura directa revocada para cliente;
- mutación sólo por RPC;
- tenant derivado server-side;
- secuencia forzada por backend;
- sin `organization_id` enviado desde Flutter.

## Core Logic

`GuidedOnboardingStep` es enum cerrado.

`GuidedOnboardingProgress` expone `nextStep`, `completedSteps` y `revision`.

`GuidedOnboardingUseCase.completeCurrentStep()` sólo envía el `nextStep` devuelto por backend y conserva la revision observada.

El gateway utiliza dos RPC literales:

- `get_my_onboarding_progress_v1`;
- `complete_my_onboarding_step_v1`.

Ambas están clasificadas por el auditor RPC global.

## Validación pendiente

T03/T04/T07/T09/T13/T14 deberán demostrar, entre otros:

- tenant nuevo inicia `in_progress`;
- tenant existente grandfathered inicia `completed`;
- operador no admin no puede completar pasos;
- revision obsoleta falla;
- saltar `modules` antes de `business_profile` falla;
- ORG_A no observa/modifica progreso de ORG_B;
- completar `review` marca `completed` y `completed_at`;
- Flutter decodifica y avanza el state machine sin enviar tenant IDs.

## Resultado

F8.2 queda cerrada a nivel de implementación como state machine de onboarding guiado, sin duplicar el dominio empresarial y con enforcement backend del orden de configuración.
