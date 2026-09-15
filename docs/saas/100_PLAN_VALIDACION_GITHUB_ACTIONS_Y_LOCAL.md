# Plan de validación — GitHub Actions primero, aceptación local al final

## Propósito

Este documento define **dónde** se ejecuta cada parte de la validación final del roadmap SaaS multi-tenant.

- `docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md` continúa siendo el **catálogo de requisitos T00–T19**.
- Este documento define la **topología de ejecución aprobada**: primero GitHub Actions en el repositorio espejo de CI y, sólo cuando CI esté verde, aceptación final local.

## Repositorios y ramas

### Repositorio fuente

- repo: `fernando15xvs/StOmni_App`
- rama: `feature/saas-multitenant-foundation`
- propósito: desarrollo y candidato oficial
- no ejecutar Actions del roadmap desde este repo
- no modificar `main`
- no hacer merge durante validación
- no aplicar migraciones SaaS al Supabase remoto

### Repositorio de CI

- repo: `fernando15xvs/StOmni_App_CI`
- rama: `feature/saas-multitenant-foundation`
- propósito: GitHub Actions y artefactos de evidencia
- debe ser un espejo exacto del candidato fuente antes de cada ejecución completa

La sincronización se realiza con:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_saas_candidate_to_ci.ps1
```

Para sincronizar y disparar la validación completa en el mismo push:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_saas_candidate_to_ci.ps1 -TriggerActions
```

El sync crea `docs/saas/CI_CANDIDATE_SOURCE.json` dentro del repo CI con el SHA exacto del candidato fuente. El workflow debe fallar si ese manifiesto no existe o no es válido.

---

# Flujo obligatorio

```text
StOmni_App / feature/saas-multitenant-foundation
            |
            | congelar commit + working tree limpio
            v
sync_saas_candidate_to_ci.ps1
            |
            v
StOmni_App_CI / feature/saas-multitenant-foundation
            |
            v
GitHub Actions — validación automática
            |
            | todos los jobs GREEN
            v
CI CANDIDATE GREEN
            |
            v
Validación local final L00–L08
            |
            v
T19 FINAL_VALIDATION_REPORT.md
            |
            +--> GO
            +--> NO-GO
```

**Un CI verde no equivale a GO.** Sólo habilita la aceptación local final.

---

# A. GitHub Actions

## CI-0 — Proveniencia del candidato

Debe registrar y validar:

- repo fuente;
- rama fuente;
- SHA fuente exacto;
- SHA del espejo CI;
- baseline SaaS presente;
- working tree del runner limpio al inicio;
- ninguna credencial de producción;
- ningún `.env` real, certificado o llave privada versionada.

**Gate:** si el manifiesto de proveniencia falta o no contiene un SHA de 40 caracteres, el workflow falla antes de validar el candidato.

## CI-1 — T00–T02: preflight, dependencias y gates estáticos

Automatizar:

- versiones Node, Flutter, Dart, Deno, Supabase y Docker;
- `flutter pub get` del workspace;
- `run_saas_t02_ci.mjs` completo;
- self-tests de los gates que los soportan;
- anti-singleton;
- RLS/RPC/Edge/security static gates;
- `deno check` de todas las Edge Functions.

**Gate:** todos los checks con exit code 0.

## CI-2 — T03/T04: Supabase limpio + contratos actuales

Automatizar en `ubuntu-latest`:

1. `supabase start`;
2. primer `supabase db reset`;
3. pgTAP del esquema actual con `scripts/run_saas_current_pgtap_ci.mjs`;
4. excluir únicamente los fingerprints históricos:
   - `fase5_production_fingerprint_test.sql`;
   - `fase5_public_snapshot_fingerprint_test.sql`;
5. `supabase db lint --local --schema public --level error --fail-on error`;
6. `supabase db diff --local --schema public` y exigir ausencia de drift.

Los fingerprints históricos se conservan como evidencia de una etapa anterior, pero no forman parte del gate del esquema SaaS final.

## CI-3 — T05–T09/T12/T14: E2E multiempresa automatizado

Ejecutar:

```bash
node supabase/tests/e2e/multi_tenant_e2e.mjs
```

Debe producir un reporte sanitizado en:

```text
.dart_tool/saas/f9_1_e2e_report.json
```

El reporte puede contener UUIDs ficticios de fixtures, pero **nunca** JWT, contraseñas, service-role keys ni secretos.

Cobertura mínima del runner actual:

- Supabase local-only;
- dos identidades Auth normales A/B;
- autoservicio de organización A/B;
- onboarding independiente A/B;
- CRUD representativo de clientes A/B;
- lectura cross-tenant por PK bloqueada;
- update cross-tenant bloqueado;
- delete cross-tenant bloqueado;
- `organization_id` falsificado bloqueado;
- onboarding B invisible desde A.

También ejecutar export tenant de ORG_A y ORG_B usando los UUID del reporte E2E.

**Importante:** este runner no sustituye los smoke visuales, cache/offline, fiscal ni la matriz adversarial completa de Edge/Storage; esas superficies quedan en la aceptación local final.

## CI-4 — T13: Flutter automatizado

En runners apropiados:

- `dart format --output=none --set-exit-if-changed`;
- `flutter analyze` para `core_logic`;
- `flutter test` para `core_logic`;
- `flutter analyze` para `mobile_app`;
- `flutter test` para `mobile_app`;
- `flutter analyze` / `flutter test` para `desktop_app`.

**Gate:** format PASS, analyze sin errores y suites verdes.

## CI-5 — T15: builds multiplataforma

### Ubuntu

- Web release;
- Android APK debug;
- Linux desktop release.

### Windows

- Windows desktop release.

### macOS

- macOS desktop release;
- iOS simulator compile smoke.

Estos builds prueban compilación real por SO, pero no reemplazan el smoke manual en dispositivo/navegador/escritorio de la fase local.

## CI-6 — T16: seguridad automatizable

Cubierta por:

- T02 `verify_saas_final_security.mjs`;
- contrato DB `final_security_contract_test.sql` dentro del pgTAP actual;
- búsqueda de archivos sensibles;
- `deno check` Edge;
- ataques cross-tenant del E2E disponible.

Los ataques dinámicos completos sobre Edge/Storage, revisión visual de logs y comportamiento de UI se confirman en local.

## CI-7 — T17: carga y concurrencia

Ejecutar:

```bash
node supabase/tests/performance/multi_tenant_concurrency_probe.mjs
```

Configuración estándar del gate CI:

```text
STOMNI_LOAD_CONCURRENCY=8
STOMNI_LOAD_CUSTOMERS_PER_TENANT=40
STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT=20
STOMNI_LOAD_READS_PER_TENANT=40
```

Guardar `.dart_tool/saas/f9_2_load_report.json` como evidencia.

El reporte puede quedar `T17_PENDING_REVIEW`; la revisión humana de p50/p95/p99 se hace antes del GO.

## CI-8 — T18: backup, restore y segunda reconstrucción

Sobre Supabase local del runner:

1. backup local;
2. restore drill destructivo permitido sólo por flag CI/local;
3. segundo `supabase db reset`;
4. re-ejecución de pgTAP actual;
5. segunda comprobación de drift;
6. artefactos JSON de evidencia.

Nunca usar Supabase remoto para este drill.

## CI-9 — Resumen

El job final sólo declara:

```text
CI CANDIDATE GREEN
```

o

```text
CI CANDIDATE NOT GREEN
```

No declara `GO`, no hace merge y no despliega.

---

# B. Validación local final — sólo después de CI verde

## L00 — Congelar exactamente el candidato que pasó CI

- rama correcta;
- SHA fuente igual al registrado en `CI_CANDIDATE_SOURCE.json`;
- working tree limpio;
- ningún cambio después del run verde.

Cualquier cambio posterior invalida la aceptación y requiere nuevo CI.

## L01 — Reconstrucción local independiente

```powershell
supabase start
supabase db reset
```

Objetivo: confirmar que el candidato que pasó en runners también reconstruye en la máquina de aceptación.

## L02 — Smoke real por plataformas disponibles

En la máquina local actual:

- Web abre y permite login;
- Android instala/inicia en emulador o dispositivo cuando esté disponible;
- Windows desktop abre e inicia;
- login + consulta tenant básica.

Los builds macOS/iOS/Linux se certifican por sus runners de CI; smoke físico adicional se registra cuando exista el hardware correspondiente.

## L03 — Cambio real ORG_A → ORG_B

Verificar manualmente:

- nombre/logo/configuración correctos;
- clientes/productos/inventario propios;
- logout A;
- login B en el mismo dispositivo;
- cero datos, branding o caché de A después de entrar a B.

## L04 — Flujo funcional crítico

Con fixtures sintéticos:

- cliente;
- producto;
- inventario;
- compra y recepción;
- venta;
- pagos/caja;
- cotización;
- comprobar que el tenant opuesto permanece sin cambios.

## L05 — Flujo fiscal

Verificar al menos:

- factura;
- respuesta exitosa;
- resultado incierto;
- conciliación;
- reintento seguro;
- nota de crédito/débito cuando aplique;
- PDF y branding fiscal.

## L06 — Offline/cache/sesión

- logout A → login B sin cache A;
- cierre/reapertura;
- offline y retorno online;
- token expirado;
- usuario disabled;
- organización suspended/closed.

## L07 — Ataques manuales adversariales

Con IDs ficticios conocidos de ORG_B desde ADMIN_A:

- SELECT por UUID B;
- UPDATE/DELETE B;
- RPC con ID B;
- Storage prefijo B;
- Edge con tenant B falsificado.

Todo debe quedar denegado o devolver cero datos según contrato.

## L08 — T19 y decisión final

Consolidar:

- SHA candidato;
- run CI verde;
- artefactos del workflow;
- resultados locales L00–L07;
- defectos y commits de corrección;
- pruebas críticas omitidas = 0;
- defectos críticos abiertos = 0.

Sólo entonces cerrar:

```text
FINAL_VALIDATION_REPORT.md
GO
```

o

```text
FINAL_VALIDATION_REPORT.md
NO-GO
```

---

# Regla de reejecución

Si falla un job de Actions:

1. diagnosticar el primer fallo real;
2. corregir únicamente en `StOmni_App/feature/saas-multitenant-foundation`;
3. no arreglar manualmente la DB del runner;
4. volver a sincronizar el candidato al repo CI;
5. ejecutar Actions otra vez;
6. no iniciar L00–L08 hasta tener CI completamente verde.

Si falla una prueba local final:

1. volver a desarrollo;
2. corregir en la rama fuente;
3. repetir CI completo;
4. sólo con CI verde reiniciar aceptación local.

## Prohibiciones permanentes

- no modificar `main` durante el proceso;
- no merge automático;
- no despliegue automático;
- no `db push` remoto;
- no `migration repair` remoto;
- no `db reset --linked`;
- no usar producción como laboratorio;
- no ocultar tests fallidos con `skip`;
- no usar `service_role` para simular un cliente normal.
