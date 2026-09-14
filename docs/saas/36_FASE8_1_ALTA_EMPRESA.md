# Fase 8.1 — Alta de empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migración:

- `supabase/migrations/20260908059000_saas_self_service_organization_signup.sql`

Core Logic:

- `onboarding/domain/organization_signup.dart`
- `onboarding/application/organization_signup_gateway.dart`
- `onboarding/application/organization_signup_use_case.dart`
- `onboarding/data/supabase_organization_signup_gateway.dart`
- `onboarding/providers/organization_signup_providers.dart`

Gate:

- `scripts/verify_saas_organization_signup.mjs`

pgTAP:

- `supabase/tests/database/organization_signup_contract_test.sql` — 18 assertions.

## Objetivo

F1.4 ya había creado el bootstrap técnico transaccional. F8.1 no duplica ese motor; crea la frontera SaaS autoservicio que una UI futura puede consumir de forma segura.

La arquitectura queda:

```text
UI autenticada
   |
OrganizationSignupUseCase
   |
create_my_organization_v1(...)
   |
bootstrap_organization_v1(...) [interno para cliente]
   |
organization + admin + configuración + capabilities + defaults
```

## Estado pre-tenant

Un usuario autenticado que todavía no pertenece a una empresa no puede usar los helpers normales basados en `current_organization_id()`. Por eso F8.1 incorpora:

`get_organization_signup_state_v1()`

El RPC sólo inspecciona `auth.uid()` y devuelve uno de tres estados:

- `eligible`;
- `attached`;
- `legacy_identity_requires_migration`.

No enumera otras organizaciones ni recibe IDs desde el cliente.

Cuando el usuario ya está vinculado, el payload puede devolver únicamente su propia organización y estados de membership/tenant para permitir routing seguro.

## Alta autoservicio

`create_my_organization_v1()` acepta exclusivamente:

- nombre comercial;
- país;
- moneda;
- timezone;
- razón social opcional.

No acepta:

- `organization_id`;
- `plan_code`;
- rol inicial;
- permisos;
- IDs de configuración;
- referencias de billing.

La identidad siempre deriva de `auth.uid()`.

## Reutilización del bootstrap

El RPC F8.1 llama a `bootstrap_organization_v1()` de F1.4. Así conserva:

- bloqueo de bootstrap concurrente del mismo usuario;
- una identidad Auth -> una empresa en V1;
- rechazo de identidades legacy no migradas;
- UUID tenant generado server-side;
- primer usuario admin;
- configuración/capabilities iniciales;
- atomicidad PostgreSQL;
- rollback completo si cualquier paso falla.

No se añadió `EXCEPTION WHEN OTHERS` que pudiera ocultar un fallo parcial.

## Cierre del bypass técnico

Antes de F8.1, `authenticated` podía ejecutar directamente `bootstrap_organization_v1()` porque todavía era el único entrypoint de alta.

F8.1 revoca ese EXECUTE al cliente. El bootstrap queda accesible desde la nueva función `SECURITY DEFINER`, pero ya no puede invocarse directamente desde Flutter/Web/Desktop.

Esto evita saltarse políticas nuevas de onboarding.

## Plan inicial

F7.2 había asignado Enterprise a organizaciones nuevas únicamente como mecanismo de transición para no reducir capacidades al introducir monetización.

F8.1 diferencia los casos:

- tenants ya existentes: conservan Enterprise `legacy_grandfathered`;
- alta autoservicio nueva: se reasigna a identidad de plan `starter` con `assignment_reason='bootstrap_default'`.

No se inventan precios ni cobros. Los entitlements actuales siguen neutrales hasta definir packaging comercial, por lo que este cambio no reduce funciones hoy.

El cliente no puede seleccionar Starter ni otro plan en el RPC; la decisión es server-side.

## Core Logic

`OrganizationSignupState` modela el routing previo a tener tenant.

`OrganizationSignupRequest` y `OrganizationSignupResult` evitan mapas libres en la UI.

`OrganizationSignupUseCase` normaliza y valida:

- nombre;
- código país de 2 letras;
- código moneda de 3 letras;
- timezone no vacío;
- razón social opcional.

La validación semántica final del timezone sigue en PostgreSQL mediante `pg_timezone_names`. El cliente no exige que la zona contenga `/`, porque valores válidos como `UTC` también existen.

El gateway Supabase usa dos RPC literales y no envía `organization_id` ni `plan_code`.

## Seguridad

- sólo `authenticated` puede consultar estado o crear empresa;
- `anon` queda revocado;
- `bootstrap_organization_v1` ya no tiene EXECUTE para `authenticated`;
- alta usa `SECURITY DEFINER` con `search_path=''`;
- organización y plan son decisiones server-side;
- no se exponen otras organizaciones;
- no se modifica directamente ninguna tabla desde Flutter.

## Gate y pgTAP

`verify_saas_organization_signup.mjs` verifica la frontera DB + runtime y está integrado en `verify_saas_rpc_surface.mjs`.

`organization_signup_contract_test.sql` congela 18 assertions sobre:

- existencia y privilegios de RPC;
- revocación del bootstrap técnico;
- identidad derivada de Auth;
- reutilización F1.4;
- Starter server-side;
- ausencia de parámetros tenant/plan manipulables;
- `SECURITY DEFINER` y search_path fijo.

## Validación dinámica pendiente

T05/T06/T07/T09/T13/T14 deberán demostrar, entre otros:

- usuario Auth sin membership obtiene `eligible`;
- usuario ya vinculado obtiene `attached` y no puede crear otra empresa;
- identidad legacy obtiene estado de migración requerida;
- dos usuarios distintos pueden crear ORG_A/ORG_B;
- cada nueva organización recibe admin/config/capabilities/branch/cash/subscription;
- alta nueva queda en Starter;
- tenants legacy no cambian de Enterprise;
- fallo inducido en cualquier dependencia revierte toda el alta;
- ORG_A nunca puede observar ORG_B mediante estado o RPC.

## Resultado

F8.1 queda cerrada a nivel de implementación como frontera autoservicio segura. La UI visual de registro/configuración pertenece a F8.2/F8.3 y la validación integral continúa pendiente de T00–T19.
