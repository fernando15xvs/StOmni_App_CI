# Fase 9.1 — E2E multiempresa

## Estado

**IMPLEMENTADA COMO SUITE / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Runner E2E:

- `supabase/tests/e2e/multi_tenant_e2e.mjs`

Gate:

- `scripts/verify_saas_multi_tenant_e2e.mjs`

F9.1 no añade tablas, migraciones, RPC ni Edge Functions. Por tanto, no crea un pgTAP nuevo: la prueba correspondiente es deliberadamente E2E sobre Auth + PostgREST + RLS + RPC públicas ya versionadas. Los contratos pgTAP de F1–F8 continúan validando el esquema y F9.1 valida su composición como producto.

## Objetivo

Versionar un escenario reproducible de dos empresas reales sobre Supabase local que use las mismas fronteras públicas que el cliente normal:

```text
Auth sintético A/B
  -> login con JWT authenticated
  -> create_my_organization_v1
  -> onboarding guiado completo
  -> CRUD representativo de negocio
  -> ataques A -> B por Data API
```

La ejecución dinámica queda integrada en T14 y se repetirá en T18 sobre una base limpia.

## Protección contra producción

El runner contiene una guarda fail-closed antes de crear cualquier fixture.

Sólo acepta:

- protocolo `http:`;
- host `127.0.0.1`;
- `localhost`;
- loopback IPv6.

Cualquier URL externa, HTTPS o proyecto `*.supabase.co` queda fuera del contrato y la suite aborta antes de operar.

Esto preserva la regla del roadmap: las pruebas SaaS se realizan en Supabase local y no se aplican ni ejercen contra el proyecto remoto.

## Separación de privilegios

`service_role` se usa exclusivamente para el provisioning de identidades Auth sintéticas mediante el endpoint administrativo local de GoTrue.

Después del provisioning:

- el login se realiza con la anon key;
- cada tenant opera con su JWT `authenticated` real;
- las llamadas RPC usan `anon key + access token`;
- el CRUD de negocio usa `anon key + access token`;
- las aserciones cross-tenant no usan `service_role`.

Así la suite ejerce RLS y autorización reales en vez de saltárselos accidentalmente con privilegios de backend.

## Alta y onboarding reales

ORG_A y ORG_B se crean en paralelo usando:

- `get_organization_signup_state_v1`;
- `create_my_organization_v1`.

No existe acceso cliente a `bootstrap_organization_v1`.

La suite exige:

- identidades nuevas `eligible`;
- UUID de organización distinto para A y B;
- plan `starter` decidido server-side;
- onboarding inicial `in_progress`;
- secuencia exacta `business_profile -> modules -> operations -> review`;
- estado final `completed` para cada tenant.

El onboarding A/B también se ejecuta en paralelo, manteniendo revision y siguiente paso por tenant.

## CRUD representativo

Después del onboarding, ambos tenants crean y actualizan un cliente por la misma Data API usada por el runtime.

El payload normal no envía `organization_id`. El runner comprueba que el backend lo derive y que la fila creada pertenezca al UUID correcto.

Esto cubre una operación real de dominio sin introducir un camino de pruebas privilegiado o distinto al cliente.

## Ataques cross-tenant automatizados

La matriz F9.1 incluye diez escenarios nominales:

1. entorno estrictamente local;
2. Auth A/B en paralelo;
3. alta autoservicio A/B;
4. onboarding A/B en paralelo;
5. CRUD de clientes A/B;
6. lectura por PK conocida de ORG_B desde ORG_A;
7. UPDATE A -> B;
8. DELETE A -> B;
9. INSERT A intentando declarar `organization_id` de B;
10. lectura explícita del progreso de onboarding B desde A.

Los criterios de aislamiento son fail-closed:

- SELECT cross-tenant devuelve cero filas;
- UPDATE cross-tenant no modifica B;
- DELETE cross-tenant no elimina B;
- spoof de `organization_id` debe fallar;
- filtro explícito por organización B no expone su progreso.

Además, después de los ataques de mutación, la suite vuelve a consultar como ORG_B para demostrar que el registro original permanece intacto.

## Gate anti-degradación

`verify_saas_multi_tenant_e2e.mjs` no intenta sustituir la ejecución dinámica. Su función es impedir que el runner pierda silenciosamente los límites que debe probar.

Comprueba, entre otros:

- guarda local-only;
- ausencia de URL Supabase remota embebida;
- `service_role` sólo en provisioning Auth;
- negocio con anon key + JWT authenticated;
- alta por `create_my_organization_v1`;
- ausencia de `bootstrap_organization_v1`;
- ORG_A/ORG_B realmente paralelos;
- onboarding completo y ordenado;
- CRUD representativo;
- ataques SELECT/UPDATE/DELETE;
- spoof de `organization_id`;
- aislamiento del progreso de onboarding;
- integración del gate en T02;
- integración del runner en T14;
- Gate Bloque 9 todavía abierto.

El gate incorpora `--self-test` con variantes seguras e inseguras para comprobar que detecta pérdida de la guarda local, uso de `service_role` en negocio, acceso al bootstrap técnico y eliminación del spoof cross-tenant.

## Integración con el mapa T00–T19

T02 ejecutará:

```text
node scripts/verify_saas_multi_tenant_e2e.mjs --self-test
node scripts/verify_saas_multi_tenant_e2e.mjs
```

T14, después de `supabase start`/`supabase db reset`, ejecutará:

```text
node supabase/tests/e2e/multi_tenant_e2e.mjs
```

T18 repetirá la ejecución sobre un segundo reset limpio.

La suite conserva fixtures sintéticos al terminar para facilitar evidencia y diagnóstico del run. La limpieza reproducible se obtiene con `supabase db reset`, no con borrados ad-hoc que puedan ocultar el estado de un fallo.

## Alcance respecto a T14

F9.1 automatiza el núcleo backend multiempresa: Auth, alta, onboarding, Data API, RLS y ataques A/B.

No declara cubiertos por inferencia los escenarios de UI/caché/offline, ventas, compras, fiscal, Storage, disabled/suspended/closed o builds multiplataforma. Esos casos permanecen explícitos en T07–T16 y deberán ejecutarse antes del GO final.

Por tanto, cerrar F9.1 significa que la **suite E2E multiempresa está implementada y versionada**, no que T14 ni el Gate Bloque 9 estén verdes.

## Validación dinámica pendiente

En T14/T18 se debe confirmar como mínimo:

- el runner arranca únicamente contra Supabase local;
- las dos identidades Auth se crean y autentican;
- ORG_A y ORG_B reciben UUID distintos;
- alta Starter y onboarding completan sin edición manual;
- CRUD propio funciona para A y B;
- lectura/mutación A -> B queda bloqueada;
- spoof de `organization_id` falla;
- el segundo run después de reset reproduce el resultado.

No se marca ningún gate dinámico por la mera existencia de esta suite.

## Resultado

F9.1 queda cerrada a nivel de implementación con un runner E2E multiempresa local, reproducible, fail-closed ante URLs remotas y con separación estricta entre provisioning privilegiado y operaciones `authenticated`. La certificación dinámica continúa deliberadamente abierta hasta T14/T18 y el Gate Bloque 9 permanece sin marcar.
