# Fase 9.5 — Seguridad final

## Estado

**IMPLEMENTADA / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

F9.5 cierra la capa estática de hardening previa al release comercial. No reemplaza las pruebas ofensivas del mapa T00–T19: congela controles que deben impedir que el candidato final llegue a esas pruebas con secretos versionados, APIs administrativas expuestas al cliente o privilegios básicos degradados.

No se ejecutó GitHub Actions, no se aplicaron migraciones SaaS al Supabase remoto y no se declara T07/T10/T11/T16/T19 como verde.

## 1. Alcance

La fase cubre cuatro fronteras:

1. higiene de secretos y archivos sensibles versionados;
2. separación cliente Flutter / backend privilegiado;
3. privilegios mínimos de esquema y ledgers internos;
4. composición con los gates ya existentes de RLS, autorización, RPC y observabilidad.

La prueba adversarial real de IDs cross-tenant, Storage, Edge Functions y estados de tenant permanece en el mapa maestro.

## 2. Gate final de seguridad

Se versiona:

```text
scripts/verify_saas_final_security.mjs
```

El gate usa `git ls-files`, por lo que inspecciona archivos realmente versionados y no depende de que un archivo sensible esté o no visible por casualidad en un listado parcial del workspace.

Rechaza como mínimo:

- `.env` real versionado;
- variantes `.env.*` que no sean el ejemplo permitido;
- `.pem`, `.key`, `.p12`, `.pfx`, `.jks`, `.keystore`;
- `id_rsa` / `id_ed25519`;
- claves privadas PEM embebidas;
- claves Supabase `sb_secret_*` embebidas.

`.env.example` queda permitido y contiene sólo configuración pública de cliente.

## 3. Frontera Flutter / backend

En `packages/core_logic`, `packages/mobile_app`, `packages/desktop_app` y cualquier árbol legacy `apps/`, el gate rechaza:

- `SUPABASE_SERVICE_ROLE_KEY`;
- secretos `sb_secret_*`;
- `FACTURACION_CRON_SECRET` / `x-cron-secret`;
- tokens internos APIsPerú;
- uso de `auth.admin`;
- invocación directa de `record_observability_event_v1`;
- claves privadas embebidas.

El cliente puede usar únicamente credenciales públicas/publishable y RPC/Edge expresamente diseñadas para usuarios autenticados.

## 4. Contrato DB final

Se versiona:

```text
supabase/tests/database/final_security_contract_test.sql
```

El contrato contiene 18 assertions y congela:

- existencia de schema `private`;
- ausencia de `USAGE` de `private` para `anon` y `authenticated`;
- RLS en `organizations`, `app_users`, `observability_events` y `audit_logs`;
- ausencia de lectura directa authenticated del ledger de observabilidad;
- ausencia de INSERT directo authenticated en `audit_logs`;
- writer de observabilidad inaccesible para `anon`/`authenticated` y ejecutable por `service_role`;
- `SECURITY DEFINER` del writer;
- RPC de métricas/errores inaccesibles para `anon` y expuestas a `authenticated` sólo detrás de su autorización tenant-admin interna.

Estas assertions se ejecutan en T04; no se consideran pasadas por estar versionadas.

## 5. Reutilización de controles previos

F9.5 no duplica gates ya cerrados. El candidato final debe conservar también:

- `verify_no_new_singletons.mjs`;
- `verify_saas_authorization.mjs`;
- `verify_saas_rls.mjs`;
- `verify_saas_rpc_surface.mjs`;
- `verify_saas_observability.mjs`.

El gate F9.5 exige que estos artefactos sigan presentes. Su ejecución real permanece en T02.

## 6. Pruebas ofensivas que siguen pendientes

### T07

- matriz SELECT/INSERT/UPDATE/DELETE A↔B;
- PK/UUID conocidos de otro tenant;
- FK/UPSERT cross-tenant;
- usuarios `anon`, sin membresía, disabled y organizaciones suspendidas/cerradas.

### T10

- Edge Functions con payload tenant falsificado;
- `service_role` siempre scopeado por tenant resuelto server-side;
- funciones administrativas con autenticación diferenciada;
- errores sin datos de otra empresa ni secretos.

### T11

- ataque a Storage con paths de otro tenant;
- lectura/escritura/listado/signing sin fuga cross-tenant.

### T16

- revisión defensiva final;
- IDs UUID de otra empresa;
- Storage cross-tenant;
- Edge con tenant falsificado;
- logs sin PII/secrets;
- ninguna operación administrativa global accesible desde Flutter normal;
- validación dinámica F9.4 de trace/job/aislamiento.

Cualquier fuga cross-tenant, secreto en cliente, PII sensible en logs o operación global accesible desde Flutter es **release blocker**.

## 7. Criterio de cierre de implementación

F9.5 puede marcarse `[x]` a nivel de implementación cuando:

- gate final está versionado con self-test;
- contrato pgTAP está versionado;
- auditoría está versionada;
- T02/T04/T16 incorporan los nuevos controles;
- checklist queda actualizado;
- `GATE BLOQUE 9 VERDE` sigue abierto.

## 8. Lo que F9.5 no certifica

F9.5 no certifica por sí sola:

- que T02 pase en la máquina candidata;
- que las 18 assertions pgTAP pasen después de `supabase db reset`;
- que un ataque A↔B real falle correctamente;
- que Storage esté aislado en runtime;
- que los logs reales estén libres de PII;
- que el producto esté listo para release.

Todo lo anterior requiere ejecución T00–T19 sobre el commit final.

## 9. Resultado

La implementación de seguridad final queda preparada para validación local integral. El siguiente paso del roadmap es **F9.6 — Release comercial**.

El **GATE BLOQUE 9 VERDE** permanece abierto hasta completar F9.6 y ejecutar las pruebas dinámicas exigidas antes de un GO comercial.
