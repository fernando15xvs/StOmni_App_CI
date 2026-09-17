# Mapa Maestro de Pruebas — StOmni SaaS Multi-Tenant

## Propósito

Este documento es la hoja de ruta única para la **validación final local** de StOmni cuando todas las fases del roadmap SaaS estén marcadas como implementadas.

Su objetivo es evitar pruebas dispersas, omisiones y falsos "verdes". Una fase puede tener sus gates parciales en verde, pero **StOmni no se considera validado para cierre del roadmap hasta completar T00–T19** y registrar la evidencia en el informe final.

> Regla principal: **ningún resultado de este documento se marca como ejecutado sólo porque el código existe o una revisión estática pasó.** Los checks finales se marcan únicamente cuando los comandos y escenarios hayan sido ejecutados en un entorno local limpio sobre el commit candidato final.

## Estado actual

- [x] Mapa maestro definido.
- [ ] Ejecución final T00–T19.
- [ ] Informe final generado.
- [ ] Cero pruebas críticas fallidas.
- [ ] Cero pruebas críticas omitidas.

## Arquitectura que debe cubrir la validación

Workspace Dart/Flutter:

- raíz: `pubspec.yaml`;
- motor reutilizable: `packages/core_logic`;
- cliente móvil: `packages/mobile_app`;
- cliente desktop: `packages/desktop_app`;
- cliente Web dedicado: **fuera del alcance actual**; se creará en una fase futura como `packages/web_app`;
- backend: `supabase/`;
- gates de arquitectura/seguridad: `scripts/`.

Plataformas soportadas por el candidato actual:

- `mobile_app`: Android e iOS;
- `desktop_app`: Windows, Linux y macOS;
- Web: no soportado por este candidato. `packages/mobile_app/web/` no debe existir.

La decisión y la evidencia que separan Web de `mobile_app` están documentadas en `docs/saas/101_AUDITORIA_FRONTERA_PLATAFORMAS_Y_WEB_FUTURA.md`. Cuando exista `web_app`, este mapa deberá ampliarse antes de declarar navegador como plataforma soportada.

## Reglas de evidencia

Para cada bloque T00–T19 se debe registrar:

1. fecha y hora;
2. commit SHA exacto;
3. versión de herramientas;
4. comando exacto;
5. código de salida;
6. resumen del resultado;
7. archivos/logs relevantes si falla;
8. corrección aplicada y nueva ejecución si corresponde.

No se aceptan como evidencia final:

- "debería funcionar";
- ejecución sobre una base ya contaminada por pruebas anteriores;
- pruebas contra producción;
- ocultar tests fallidos con `skip`;
- desactivar RLS o constraints para hacer pasar la suite;
- usar `service_role` para simular un cliente normal.

---

# T00 — Preflight y reproducibilidad del entorno

## Objetivo

Asegurar que las pruebas se ejecuten sobre el commit correcto y con herramientas compatibles.

## Checklist

- [ ] `git status` limpio.
- [ ] rama/commit candidato registrados.
- [ ] `git diff` vacío antes de empezar.
- [ ] `flutter --version` registrado.
- [ ] `dart --version` registrado.
- [ ] `node --version` registrado.
- [ ] `supabase --version` registrado.
- [ ] `psql --version` registrado.
- [ ] `pg_dump --version` registrado.
- [ ] `pg_restore --version` registrado.
- [ ] `docker --version` y disponibilidad de Docker registrados.
- [ ] Java/Android SDK registrados para Android.
- [ ] Visual Studio C++ toolchain disponible para Windows desktop.
- [ ] Xcode/CocoaPods disponibles cuando se ejecute iOS/macOS en macOS.
- [ ] no se utilizan credenciales de producción.
- [ ] variables `.env`/`--dart-define` apuntan exclusivamente al laboratorio local.

Comandos base:

```bash
git status
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
flutter --version
dart --version
node --version
supabase --version
psql --version
pg_dump --version
pg_restore --version
docker --version
```

**Salida:** entorno reproducible y commit congelado.

---

# T01 — Resolución del workspace y dependencias

## Objetivo

Demostrar que el workspace completo resuelve dependencias desde cero.

## Ejecución

Desde la raíz:

```bash
flutter clean
flutter pub get
```

Después verificar cada miembro:

```bash
cd packages/core_logic && flutter pub get
cd ../mobile_app && flutter pub get
cd ../desktop_app && flutter pub get
```

## Criterios

- [ ] sin conflictos de versiones;
- [ ] sin paquetes faltantes;
- [ ] workspace `core_logic/mobile_app/desktop_app` resuelto;
- [ ] no depende de artefactos locales no versionados.

---

# T02 — Gates estáticos SaaS y anti-regresión

## Objetivo

Bloquear la reintroducción de singleton y validar los contratos estructurales SaaS.

```bash
node scripts/verify_no_new_singletons.mjs --self-test
node scripts/verify_no_new_singletons.mjs
node scripts/verify_saas_foundation.mjs --self-test
node scripts/verify_saas_foundation.mjs
node scripts/verify_saas_authorization.mjs --self-test
node scripts/verify_saas_authorization.mjs
node scripts/verify_saas_rls.mjs --self-test
node scripts/verify_saas_rls.mjs
node scripts/verify_saas_domain_configuration.mjs --self-test
node scripts/verify_saas_domain_configuration.mjs
node scripts/verify_saas_customers_suppliers.mjs --self-test
node scripts/verify_saas_customers_suppliers.mjs
node scripts/verify_saas_catalog_foundation.mjs --self-test
node scripts/verify_saas_catalog_foundation.mjs
node scripts/verify_saas_inventory.mjs --self-test
node scripts/verify_saas_inventory.mjs
node scripts/verify_saas_inventory_runtime.mjs --self-test
node scripts/verify_saas_inventory_runtime.mjs
node scripts/verify_saas_inventory_surface.mjs --self-test
node scripts/verify_saas_inventory_surface.mjs
node scripts/verify_saas_sales.mjs --self-test
node scripts/verify_saas_sales.mjs
node scripts/verify_saas_purchases.mjs --self-test
node scripts/verify_saas_purchases.mjs
node scripts/verify_saas_organization_signup.mjs --self-test
node scripts/verify_saas_organization_signup.mjs
node scripts/verify_saas_guided_onboarding.mjs --self-test
node scripts/verify_saas_guided_onboarding.mjs
node scripts/verify_saas_onboarding_ux.mjs --self-test
node scripts/verify_saas_onboarding_ux.mjs
node scripts/verify_saas_business_branding.mjs --self-test
node scripts/verify_saas_business_branding.mjs
node scripts/verify_saas_multi_tenant_e2e.mjs --self-test
node scripts/verify_saas_multi_tenant_e2e.mjs
node scripts/verify_saas_load_concurrency.mjs --self-test
node scripts/verify_saas_load_concurrency.mjs
node scripts/verify_saas_backup_recovery.mjs --self-test
node scripts/verify_saas_backup_recovery.mjs
node scripts/verify_saas_observability.mjs --self-test
node scripts/verify_saas_observability.mjs
node scripts/verify_saas_final_security.mjs --self-test
node scripts/verify_saas_final_security.mjs
node scripts/verify_saas_release_readiness.mjs --self-test
node scripts/verify_saas_release_readiness.mjs
node scripts/verify_saas_rpc_surface.mjs --self-test
node scripts/verify_saas_rpc_surface.mjs
```

Cuando se creen nuevos gates durante el roadmap, deberán agregarse también a T02.

Además del runner anterior, el workflow final debe mantener un gate de frontera de plataformas que compruebe que `mobile_app` conserva Android/iOS y que `packages/mobile_app/web/` no reaparece antes de la fase Web dedicada.

## Criterios

- [ ] todos los self-tests verdes;
- [ ] todos los gates verdes;
- [ ] cero singleton nuevos;
- [ ] cero excepciones nuevas sin auditoría explícita;
- [ ] frontera de plataformas vigente: mobile Android/iOS, desktop Windows/Linux/macOS, Web diferido.

---

# T03 — Supabase local desde cero

## Objetivo

Probar la historia completa de migraciones, no sólo el estado final de una base previamente modificada.

## Ejecución prevista

```bash
supabase start
supabase db reset
```

Después de ejecutar las suites dependientes de DB, repetir:

```bash
supabase db reset
```

## Verificaciones

- [ ] todas las migraciones se aplican en orden;
- [ ] ninguna migración falla;
- [ ] no existen dependencias manuales fuera del repositorio;
- [ ] seeds/fixtures de prueba son reproducibles;
- [ ] el segundo reset produce el mismo esquema;
- [ ] no existe drift entre migraciones y esquema esperado;
- [ ] Edge Functions/config local necesarios pueden iniciarse.

**Prohibido:** arreglar la DB manualmente desde Studio y continuar sin convertir el arreglo en migración versionada.

---

# T04 — Contratos e invariantes de esquema

## Objetivo

Verificar mediante SQL el modelo final multi-tenant.

## Matriz mínima

- [ ] `organizations.id` UUID e inmutable;
- [ ] `app_users.user_id -> auth.users.id`;
- [ ] un usuario pertenece a una sola organización en V1;
- [ ] tablas tenant-owned tienen `organization_id` donde corresponda;
- [ ] `organization_id` requerido tras backfills definitivos;
- [ ] FKs compuestas impiden referencias cross-tenant;
- [ ] unicidades de negocio están scopeadas por organización;
- [ ] no quedan `business_id = 1`, `id = 1`, `limit(1)` singleton u otros atajos equivalentes;
- [ ] índices comienzan por `organization_id` en paths tenant críticos cuando corresponde;
- [ ] todas las tablas expuestas al cliente tienen RLS habilitado;
- [ ] grants y permisos son explícitos;
- [ ] funciones públicas tienen `EXECUTE` revisado;
- [ ] funciones privilegiadas tienen `search_path` seguro.
- [ ] `business_branding_contract_test.sql` confirma que nombre/logo provienen de `configuracion_negocio` y que la RPC deriva el tenant.
- [ ] `load_concurrency_contract_test.sql` valida idempotencia tenant-local, índices tenant-leading, locks de inventario y correlativos fiscales concurrentes.
- [ ] `observability_contract_test.sql` valida ledger interno, RLS/grants, writer service-role-only, métricas tenant-admin y superficie sin payload/PII.
- [ ] `final_security_contract_test.sql` valida schema `private`, RLS de fronteras críticas, ledgers internos y `EXECUTE` mínimo del writer/RPC de observabilidad.

---

# T05 — Fixtures sintéticos de dos empresas

## Objetivo

Crear la base controlada sobre la que se realizará toda prueba de aislamiento.

Fixture mínimo:

```text
ORG_A
  ADMIN_A
  OPERADOR_A
  EMPLEADO_A_SIN_LOGIN

ORG_B
  ADMIN_B
  OPERADOR_B

USUARIO_DISABLED
ORG_SUSPENDED
ORG_CLOSED
AUTH_SIN_APP_USER
```

Además, cada organización deberá tener datos propios en los dominios ya migrados: clientes, productos, almacenes, inventario, ventas, compras, caja, documentos fiscales, etc.

## Reglas

- [ ] sólo datos ficticios;
- [ ] IDs A/B guardados para assertions;
- [ ] ningún fixture requiere edición manual de DB;
- [ ] fixture recreable después de `supabase db reset`.

---

# T06 — Bootstrap transaccional de empresa

## Objetivo

Probar que el onboarding técnico crea una empresa completa y consistente.

Escenarios obligatorios:

- [ ] usuario autenticado sin empresa puede iniciar bootstrap;
- [ ] se crea `organization`;
- [ ] se crea/vincula `app_user` como admin;
- [ ] se crea configuración inicial tenant-aware;
- [ ] se crean capacidades/módulos default tenant-aware;
- [ ] el `organization_id` se deriva/crea server-side y no se confía en uno enviado por Flutter;
- [ ] el resultado devuelve la organización creada;
- [ ] un segundo bootstrap del mismo usuario no crea otra empresa accidentalmente;
- [ ] fallo inducido a mitad de operación hace rollback total;
- [ ] después del rollback no quedan organizaciones, usuarios, configuración ni capacidades huérfanas;
- [ ] dos admins distintos pueden crear ORG_A y ORG_B sin edición manual de DB.

---

# T07 — Matriz RLS de aislamiento cross-tenant

## Objetivo

Demostrar aislamiento real usando tokens de usuarios normales, no `service_role`.

Para cada tabla tenant-owned relevante ejecutar como ADMIN_A/OPERADOR_A:

| Operación | Dato ORG_A | Dato ORG_B |
|---|---|---|
| SELECT | según rol: permitido | **0 filas / denegado** |
| INSERT | según rol: permitido | **denegado** |
| UPDATE | según rol: permitido | **denegado** |
| DELETE | según rol: permitido | **denegado** |

Ataques obligatorios:

- [ ] enviar `organization_id` de ORG_B desde cliente A;
- [ ] usar PK conocida de un registro de ORG_B;
- [ ] intentar FK cross-tenant;
- [ ] intentar UPSERT cross-tenant;
- [ ] intentar filtrar explícitamente por ORG_B;
- [ ] `gastos` y `pagos_gasto` de ORG_B no aparecen en SELECT de ORG_A;
- [ ] `purchase_orders`, líneas y recepciones no son accesibles directamente por Data API autenticada;
- [ ] proveedor/almacén/producto de ORG_B no pueden relacionarse con una orden ORG_A;
- [ ] línea/recepción ORG_B no puede relacionarse con cabecera ORG_A;
- [ ] `pagos_deuda_requests` rechaza `deuda_id` de venta/gasto perteneciente a otro tenant;
- [ ] usuario `anon`;
- [ ] Auth válido sin `app_users`;
- [ ] `app_user.status = disabled`;
- [ ] organización `suspended`;
- [ ] organización `closed`;
- [ ] repetir matriz A -> B y B -> A.

**Criterio crítico:** cero lectura o mutación cross-tenant.

---

# T08 — Empleados vs acceso

## Objetivo

Probar la separación introducida por Fase 1.3 y su estado final.

- [ ] crear empleado sin cuenta Auth/app_user;
- [ ] crear empleado con app_user de su misma organización;
- [ ] enlazar empleado A con app_user B -> rechazado;
- [ ] enlazar dos empleados al mismo app_user -> rechazado;
- [ ] mismo email de contacto en ORG_A y ORG_B -> permitido;
- [ ] mismo email duplicado dentro de ORG_A -> rechazado;
- [ ] deshabilitar acceso no elimina ficha de empleado salvo regla explícita;
- [ ] eliminar/desvincular acceso conserva integridad laboral según diseño final;
- [ ] no se usa email de empleado como autenticación implícita.

---

# T09 — RPC tenant-aware

## Objetivo

Validar todos los RPC expuestos o usados por la aplicación.

Para cada RPC de negocio:

- [ ] tenant derivado desde `auth.uid()`/contexto autorizado;
- [ ] `organization_id` aportado por cliente no puede elevar alcance;
- [ ] IDs cross-tenant son rechazados o producen cero datos;
- [ ] consultas y mutaciones siempre filtran tenant;
- [ ] `SECURITY INVOKER` usado cuando es suficiente;
- [ ] cada `SECURITY DEFINER` restante tiene justificación y auditoría;
- [ ] `search_path` explícito/seguro;
- [ ] grants `EXECUTE` mínimos;
- [ ] usuario disabled/no-org no puede ejecutar operación empresarial;
- [ ] organización suspendida/cerrada se comporta según contrato.

Escenarios específicos de ventas/compras:

- [ ] `process_sale_v4` y `process_sale_with_units_v4` rechazan cliente/producto/almacén/cotización de ORG_B desde ORG_A;
- [ ] `guardar_cotizacion_v2` y su variante de unidades no crean detalles cross-tenant;
- [ ] `procesar_pago_deuda_v2` sólo acepta venta/gasto del tenant autenticado;
- [ ] `create_purchase_order_v1` rechaza proveedor, almacén o producto de ORG_B;
- [ ] `list_purchase_orders_v1` de ORG_A nunca devuelve órdenes ORG_B;
- [ ] `cancel_purchase_order_v1` no puede mutar orden ORG_B;
- [ ] `receive_purchase_order_v2` no puede recibir orden/línea ORG_B ni alterar inventario B;
- [ ] el mismo `request_id` puede coexistir en ORG_A y ORG_B para órdenes/recepciones sin colisión ni fuga;
- [ ] `registrar_gasto_mixto`, `eliminar_gasto_v1` y `eliminar_pago_gasto_v1` rechazan IDs cross-tenant;
- [ ] pago a proveedor no-cash funciona sólo en su tenant;
- [ ] pagos que afectan Caja Chica permanecen rechazados hasta cerrar F4.3;
- [ ] RPC legacy revocados no pueden ejecutarse como `authenticated`.

---

# T10 — Edge Functions y rutas con service_role

## Objetivo

Probar que saltarse RLS con `service_role` no equivale a saltarse el tenant.

Para cada Edge Function:

- [ ] valida JWT cuando corresponda;
- [ ] resuelve `app_user` y organización server-side;
- [ ] no confía en `organization_id` del body/query/header;
- [ ] toda consulta service-role aplica `organization_id` explícitamente;
- [ ] referencias cross-tenant rechazadas;
- [ ] errores no filtran secretos ni datos de otra empresa;
- [ ] procesos fiscales incluidos;
- [ ] guías de remisión incluidas;
- [ ] operaciones de storage incluidas;
- [ ] funciones administrativas internas tienen autenticación diferenciada.

---

# T11 — Storage multi-tenant

## Objetivo

Validar aislamiento de archivos.

Convención esperada:

```text
<organization_id>/<recurso...>
```

Escenarios:

- [ ] ORG_A sube archivo en prefijo A;
- [ ] ORG_A lista/descarga su archivo según permisos;
- [ ] ORG_A no lista archivo B;
- [ ] ORG_A no descarga archivo B;
- [ ] ORG_A no reemplaza archivo B;
- [ ] ORG_A no elimina archivo B;
- [ ] ruta falsificada con UUID B rechazada;
- [ ] buckets sensibles privados;
- [ ] URLs firmadas expiran y no permiten enumeración cross-tenant;
- [ ] policies `storage.objects` tenant-aware.
- [ ] logos de ORG_A y ORG_B usan `<organization_id>/logos/...` y no pueden sobrescribirse entre tenants.

---

# T12 — Regresión funcional de dominio

## Objetivo

Comprobar que convertir StOmni en SaaS no rompe el negocio existente.

Ejecutar CRUD + reglas principales, siempre con datos A/B, para:

- [ ] configuración de empresa;
- [ ] branding: nombre comercial/logo se propagan a Mobile, Desktop y PDFs;
- [ ] usuarios y empleados;
- [ ] clientes;
- [ ] proveedores;
- [ ] categorías;
- [ ] productos/variantes;
- [ ] almacenes;
- [ ] inventario/stock/movimientos;
- [ ] compras;
- [ ] ventas;
- [ ] cotizaciones si aplican;
- [ ] pagos/cuentas por cobrar/pagar;
- [ ] caja;
- [ ] precios/descuentos;
- [ ] facturación fiscal;
- [ ] notas de crédito/débito si aplican;
- [ ] guías de remisión;
- [ ] reportes;
- [ ] auditoría;
- [ ] capabilities/módulos;
- [ ] sucursales/cajas cuando existan;
- [ ] suscripciones/entitlements cuando existan.

Regresión específica de compras:

- [ ] crear orden A con proveedor/almacén/productos A y conservar cantidades/costos;
- [ ] recibir parcialmente y luego completar una orden A;
- [ ] cada recepción incrementa únicamente inventario de ORG_A;
- [ ] lotes/seriales de recepción conservan tenant cuando la trazabilidad está activa;
- [ ] anular una orden sin recepción funciona y una con mercadería recibida se rechaza;
- [ ] reintentar `request_id` dentro del mismo tenant es idempotente;
- [ ] usar el mismo UUID en ORG_A y ORG_B crea operaciones independientes;
- [ ] registrar gasto y pagos no-cash recalcula saldo/estado sólo en su tenant;
- [ ] deuda a proveedor no-cash reduce únicamente el gasto correcto;
- [ ] Caja Chica sigue fail-closed hasta F4.3.

Exportación por empresa F9.3, usando únicamente fixtures sintéticos:

```bash
node scripts/saas_export_tenant.mjs --organization-id <ORG_A_UUID>
node scripts/saas_export_tenant.mjs --organization-id <ORG_B_UUID>
```

- [ ] export ORG_A contiene su fila raíz y sólo filas `organization_id=ORG_A`;
- [ ] export ORG_B contiene su fila raíz y sólo filas `organization_id=ORG_B`;
- [ ] ningún JSONL de A contiene datos tenant-owned de B y viceversa;
- [ ] Storage exportado queda únicamente bajo el prefijo del tenant solicitado;
- [ ] el manifest declara que no incluye hashes de contraseña, sesiones ni tokens Auth;
- [ ] conteos/fingerprints del manifest coinciden con la DB local.

Cada prueba funcional deberá verificar también que ORG_B permanece sin cambios.

---

# T13 — Flutter: formato, análisis, unit y widget tests

## Objetivo

Dejar el workspace Dart/Flutter sin errores estáticos y con todas las pruebas automatizadas verdes.

### Formato

Desde la raíz:

```bash
dart format --output=none --set-exit-if-changed packages
```

### Analyze

```bash
flutter analyze packages/core_logic
flutter analyze packages/mobile_app
flutter analyze packages/desktop_app
```

Si el SDK/workspace soporta análisis correcto desde raíz, registrar también:

```bash
flutter analyze
```

### Tests

```bash
cd packages/core_logic
flutter test

cd ../mobile_app
flutter test

cd ../desktop_app
flutter test
```

## Cobertura funcional mínima de tests Flutter

- [ ] tenant context/resolution;
- [ ] repositories no inyectan singleton IDs;
- [ ] mappers preservan tenant;
- [ ] permisos/roles;
- [ ] estado disabled/suspended;
- [ ] configuración/capabilities;
- [ ] errores cross-tenant no se convierten en datos válidos;
- [ ] logout limpia caches tenant;
- [ ] cambio de sesión no reutiliza cache de la empresa anterior;
- [ ] UI V1 no expone selector de tenant no autorizado;
- [ ] widgets críticos renderizan correctamente.
- [ ] routing compartido cubre password -> alta -> onboarding -> Home;
- [ ] `organizationSetupRequired` nunca abre Home ni autorización offline;
- [ ] onboarding incompleto nunca abre Home;
- [ ] autorización offline válida abre Home sin consultar onboarding remoto;
- [ ] logout ORG_A -> login ORG_B no reutiliza progreso de onboarding.
- [ ] `BusinessBrandingMapper` valida tenant, fallback de nombre y URL de logo;
- [ ] caché visual offline expira y no se reutiliza entre usuarios;
- [ ] logout/cambio de sesión limpia el snapshot fiscal usado por PDFs;
- [ ] renderizadores PDF aceptan nombre comercial distinto de razón social.

**Criterio:** `flutter analyze` = 0 errores y toda la suite `flutter test` verde.

---

# T14 — Integración y E2E

## Objetivo

Probar flujos reales contra Supabase local.

Automatización backend multiempresa F9.1, después de `supabase db reset`:

```bash
node supabase/tests/e2e/multi_tenant_e2e.mjs
```

- [ ] runner F9.1 completa sus 10 escenarios con ORG_A/ORG_B y tokens `authenticated`.

Escenarios mínimos:

- [ ] ADMIN_A login -> sólo ORG_A;
- [ ] ADMIN_B login -> sólo ORG_B;
- [ ] Auth sin tenant -> alta -> revalidación online -> onboarding -> Home;
- [ ] restauración con cambio obligatorio de contraseña -> login/alta/onboarding según corresponda;
- [ ] onboarding incompleto bloquea Home en Mobile/Desktop;
- [ ] autorización offline tenant válida abre Home sin RPC de onboarding;
- [ ] crear cliente/producto/stock en A;
- [ ] registrar venta A y verificar impacto inventario/caja;
- [ ] crear OC A, recibirla y verificar inventario A;
- [ ] registrar gasto/deuda a proveedor A y abono no-cash;
- [ ] repetir flujo de compra/deuda en B usando incluso el mismo UUID de request y comprobar independencia;
- [ ] flujo fiscal A;
- [ ] repetir recorrido básico en B;
- [ ] comprobar que A y B nunca se mezclan;
- [ ] logout A -> login B en el mismo dispositivo sin datos cacheados de A;
- [ ] ORG_A y ORG_B muestran nombres/logos distintos en Mobile y Desktop;
- [ ] logout A -> login B no conserva logo, nombre ni perfil fiscal de A;
- [ ] modo offline muestra sólo el snapshot visual del usuario autorizado y no consulta otro tenant;
- [ ] cotización y ticket usan nombre comercial, razón social y logo del tenant actual;
- [ ] usuario disabled rechazado;
- [ ] organización suspended/closed rechazada según contrato;
- [ ] conectividad/reintento no duplica transacciones críticas.

La automatización F9.1 cubre el núcleo backend Auth/alta/onboarding/RLS/CRUD; los escenarios de UI, caché/offline, ventas, compras, fiscal y estados disabled/suspended/closed continúan siendo obligatorios y no se consideran cubiertos por inferencia.

Cuando exista `integration_test/`, la suite de UI debe ejecutarse automatizadamente; mientras no exista, el caso faltante debe registrarse como deuda antes del cierre final, no omitirse silenciosamente.

---

# T15 — Builds y smoke tests por plataforma

## Objetivo

Demostrar que la separación `core_logic` permite compilar las plataformas declaradas como soportadas por los clientes actuales. Web no forma parte de este candidato; su interfaz se implementará en `packages/web_app` durante una fase futura independiente.

### En Windows — obligatorio para la máquina local actual

Mobile Android, cuando exista emulador/dispositivo disponible:

```bash
cd packages/mobile_app
flutter build apk --debug
```

Desktop Windows:

```bash
cd packages/desktop_app
flutter build windows --release
```

Smoke manual/automatizado:

- [ ] Android inicia en emulador/dispositivo cuando esté disponible;
- [ ] Windows desktop inicia;
- [ ] login y consulta tenant básica funcionan en cada plataforma realmente disponible;
- [ ] branding responsive verificado en teléfono/tablet móvil y Desktop;
- [ ] logo ausente/URL fallida conserva un fallback visual y no bloquea Home;
- [ ] `packages/mobile_app/web/` permanece ausente y CI no ejecuta `flutter build web` sobre `mobile_app`.

### En macOS — requerido antes de considerar iOS/macOS comercialmente verdes

```bash
cd packages/mobile_app
flutter build ios --no-codesign

cd ../desktop_app
flutter build macos --release
```

- [ ] iOS compila sin firma;
- [ ] macOS desktop compila;
- [ ] smoke básico realizado cuando exista hardware disponible.

### En Linux — requerido antes de declarar Linux desktop soportado

```bash
cd packages/desktop_app
flutter build linux --release
```

- [ ] Linux compila;
- [ ] smoke básico realizado cuando exista hardware disponible.

**Nota:** una máquina Windows no puede certificar por sí sola un build iOS/macOS. Esas casillas deberán ejecutarse en macOS o certificarse por el runner correspondiente antes del release multiplataforma; no se marcarán por inferencia. La ausencia de un build Web no cuenta como prueba omitida porque Web no está declarado como plataforma soportada por este candidato.

---

# T16 — Hardening de seguridad

## Objetivo

Ejecutar revisión defensiva además de las pruebas funcionales.

Gate F9.5:

```bash
node scripts/verify_saas_final_security.mjs --self-test
node scripts/verify_saas_final_security.mjs
```

Contrato DB, ejecutado dentro de T04:

```text
supabase/tests/database/final_security_contract_test.sql
```

- [ ] ninguna `service_role` key dentro de los clientes Flutter soportados;
- [ ] ningún secreto versionado;
- [ ] anon key tratada como pública, seguridad basada en RLS;
- [ ] grants a `anon`/`authenticated` revisados;
- [ ] `EXECUTE` de funciones revisado;
- [ ] todos los `SECURITY DEFINER` inventariados;
- [ ] `search_path` de funciones privilegiadas fijado;
- [ ] SQL injection/inputs manipulados en RPC revisados;
- [ ] IDs UUID de otra empresa probados adversarialmente;
- [ ] Storage cross-tenant atacado;
- [ ] URL de logo `file:`, `data:` y HTTP remoto rechazada; HTTPS/loopback válidos conservados;
- [ ] branding offline no concede autorización y su caché queda aislada por usuario/backend;
- [ ] Edge Functions atacadas con payloads tenant falsificados;
- [ ] logs/errores no revelan PII o secretos innecesarios;
- [ ] ninguna operación administrativa global accesible desde Flutter normal.
- [ ] `git ls-files` no contiene `.env` real, certificados ni llaves privadas;
- [ ] el gate F9.5 confirma ausencia de service-role/cron/APIsPeru secrets, `auth.admin` y writers internos en clientes Flutter.

Validación dinámica F9.4 con fixtures sintéticos ORG_A/ORG_B:

- [ ] cada Edge probada devuelve `x-stomni-trace-id` UUID;
- [ ] un `x-stomni-trace-id` UUID válido enviado por cliente se conserva para correlación pero nunca altera el tenant resuelto server-side;
- [ ] un trace inválido es reemplazado por un UUID nuevo;
- [ ] ADMIN_A sólo puede consultar métricas/errores sanitizados de ORG_A;
- [ ] ADMIN_B sólo puede consultar métricas/errores sanitizados de ORG_B;
- [ ] 401/403 se registran como `denied` y no exponen PII;
- [ ] un batch sin candidatos devuelve `job_id` y queda `skipped`;
- [ ] un fallo parcial controlado queda `failed` con `BATCH_PARTIAL_FAILURE`;
- [ ] revisión de logs locales confirma ausencia de JWT, Authorization, email, DNI/RUC, secretos, URLs sensibles y payloads crudos;
- [ ] cualquier evidencia `TENANT_ISOLATION_VIOLATION` o `PII_SECRET_LOG_EXPOSURE` bloquea release;
- [ ] se registra línea base local de tasa `failed`, p95 y p99 para calibrar alertas sin declararla SLA.

---

# T17 — Performance y planes tenant-aware

## Objetivo

Evitar que RLS/tenant filtering haga inviable el crecimiento multiempresa y medir la contención real sobre dos tenants independientes.

## Probe automatizado F9.2

Después de `supabase db reset` y con el stack local iniciado:

```bash
node supabase/tests/performance/multi_tenant_concurrency_probe.mjs
```

Configuración reproducible por defecto:

```text
STOMNI_LOAD_CONCURRENCY=8
STOMNI_LOAD_CUSTOMERS_PER_TENANT=40
STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT=20
STOMNI_LOAD_READS_PER_TENANT=40
```

Se pueden ajustar estas variables dentro de los límites fail-closed del runner, pero todo informe debe registrar los valores usados.

Evidencia esperada:

```text
.dart_tool/saas/f9_2_load_report.json
```

- [ ] ORG_A y ORG_B reciben carga simultánea con JWT `authenticated` normales;
- [ ] burst de clientes mantiene aislamiento A/B;
- [ ] lecturas concurrentes no exponen otro tenant;
- [ ] mismo `request_id` simultáneo dentro de un tenant afecta inventario exactamente una vez;
- [ ] mismo `request_id` simultáneo en ORG_A y ORG_B prospera de forma independiente;
- [ ] burst de inventario deja delta exacto igual al número de operaciones;
- [ ] p50/p95/p99 quedan registrados por familia de operación;
- [ ] el reporte permanece `T17_PENDING_REVIEW` hasta revisión humana del baseline.

## Correlativos concurrentes

Con fixtures fiscales sintéticos locales:

- [ ] dos workers del mismo tenant/tipo/fecha no generan correlativos tributarios duplicados;
- [ ] `FOR UPDATE SKIP LOCKED` evita adjudicar la misma solicitud a dos procesos;
- [ ] ORG_A y ORG_B pueden usar el mismo tipo/fecha y mantener correlativos independientes;
- [ ] dos ventas fiscales concurrentes de la misma organización/serie no reciben el mismo correlativo;
- [ ] una serie de ORG_A no incrementa ni bloquea la serie de ORG_B.

## Planes e índices

Para consultas críticas:

- [ ] `EXPLAIN (ANALYZE, BUFFERS)` sobre datos sintéticos suficientes;
- [ ] filtros por `organization_id` usan índices apropiados;
- [ ] FKs compuestas tienen índices de soporte cuando corresponde;
- [ ] policies no ejecutan helpers costosos fila por fila sin necesidad;
- [ ] listados usan paginación;
- [ ] reportes no hacen full scan global evitable;
- [ ] consultas de inventario/ventas/clientes/productos/compras revisadas;
- [ ] no hay degradación extrema entre una y múltiples organizaciones.

F9.2 no fija todavía un SLO comercial. Registrar baseline de hardware, tamaños de fixture, percentiles y planes para decidir umbrales de GO con evidencia.

---

# T18 — Doble ejecución limpia

## Objetivo

Detectar dependencia accidental del orden o de residuos de una ejecución anterior y demostrar que un snapshot StOmni puede reconstruirse en Supabase local.

Secuencia:

1. `supabase db reset`;
2. recrear fixtures;
3. ejecutar suite crítica T02–T17 aplicable;
4. crear un backup F9.3 del estado controlado;
5. ejecutar restore drill destructivo sobre ese backup;
6. repetir assertions críticas sobre el estado restaurado;
7. destruir/resetear entorno;
8. repetir desde cero.

Comandos F9.3 de referencia en PowerShell, usando una ruta determinista:

```powershell
$env:STOMNI_SAAS_BACKUP_DIR = ".dart_tool/saas/backups/t18-run1"
node scripts/saas_backup_local.mjs
$env:STOMNI_ALLOW_DESTRUCTIVE_RESTORE = "YES"
node scripts/saas_restore_drill_local.mjs ".dart_tool/saas/backups/t18-run1"
Remove-Item Env:STOMNI_ALLOW_DESTRUCTIVE_RESTORE
Remove-Item Env:STOMNI_SAAS_BACKUP_DIR
```

Evidencia obligatoria:

```text
.dart_tool/saas/f9_3_restore_report.json
```

## Criterios

- [ ] RUN 1 verde;
- [ ] RUN 2 verde;
- [ ] el probe F9.2 se repite después del segundo reset y conserva aislamiento/idempotencia;
- [ ] percentiles y hardware de ambos runs quedan registrados para comparación, sin exigir igualdad exacta;
- [ ] backup F9.3 registra el commit exacto y no cambia fingerprints durante la captura;
- [ ] restore reconstruye esquema desde migraciones y datos desde dumps sin correcciones manuales;
- [ ] fingerprints de todas las tablas `public`, `auth.users` y `auth.identities` coinciden exactamente;
- [ ] inventario, tamaño y SHA-256 de todos los objetos Storage coinciden exactamente;
- [ ] `f9_3_restore_report.json` termina en `RESTORE_DRILL_GREEN`;
- [ ] mismos invariantes y conteos esperados;
- [ ] ninguna prueba depende de datos residuales;
- [ ] ninguna corrección manual entre runs.

---

# T19 — Informe de validación final y decisión Go/No-Go

Usar como base la plantilla versionada:

```text
docs/saas/FINAL_VALIDATION_REPORT_TEMPLATE.md
```

Copiarla durante T19 a:

```text
docs/saas/FINAL_VALIDATION_REPORT.md
```

La plantilla no es evidencia y permanece con `DECISIÓN: PENDIENTE` hasta la ejecución real.

Debe contener:

- commit SHA final;
- sistema operativo de cada plataforma probada;
- versiones Flutter/Dart/Node/Supabase/PostgreSQL/psql/pg_dump/pg_restore;
- resultado T00–T19;
- comandos ejecutados;
- conteo de tests passed/failed/skipped;
- resultado de `flutter analyze`;
- resultado de `flutter test` por paquete;
- resultado de `supabase db reset`;
- matriz ORG_A/ORG_B;
- builds realizados;
- plataformas declaradas como soportadas y evidencia de que Web permanece diferido a un cliente dedicado;
- hallazgos de seguridad;
- hallazgos de performance;
- evidencia `.dart_tool/saas/f9_3_restore_report.json`;
- tiempo real medido del restore drill;
- RPO/RTO y retención realmente aprobados para el plan/proveedor contratado, sin inferir valores no medidos;
- resultado de exportación tenant ORG_A/ORG_B;
- resultado F9.4 T02/T04/T16 y confirmación de aislamiento de observabilidad ORG_A/ORG_B;
- ejemplos ficticios de `trace_id` y `job_id` usados como evidencia de correlación;
- p50/p95/p99 de observabilidad medidos localmente y conteos `failed`/`denied`;
- confirmación de revisión de logs sin PII/secretos y ausencia de `TENANT_ISOLATION_VIOLATION`/`PII_SECRET_LOG_EXPOSURE`;
- línea base y umbrales operativos de alerta aprobados antes de producción, sin inferirlos como SLA;
- resultado F9.5 de T02/T04/T07/T10/T11/T16;
- confirmación de que no existen archivos sensibles versionados ni secretos/APIs administrativas de backend accesibles desde Flutter;
- resultado del gate F9.6 `verify_saas_release_readiness.mjs`;
- confirmación de revisión de `RELEASE_RUNBOOK.md`, estrategia de backup/rollback y plataformas autorizadas por T15;
- defectos encontrados y commits de corrección;
- desviaciones conocidas;
- pruebas críticas omitidas: **debe ser 0**;
- decisión final `GO` o `NO-GO`.

## Criterio GO

Sólo se podrá declarar **StOmni SaaS final verde** cuando:

- [ ] T00–T19 completos;
- [ ] `flutter analyze` sin errores;
- [ ] todas las suites `flutter test` verdes;
- [ ] migraciones desde cero verdes dos veces;
- [ ] aislamiento A/B demostrado para lectura y escritura;
- [ ] RPC/Edge/Storage tenant-safe;
- [ ] restore drill F9.3 verde con fingerprints DB y hashes Storage exactos;
- [ ] RPO/RTO/retención de producción definidos sobre capacidades reales del proveedor;
- [ ] observabilidad F9.4 validada dinámicamente con aislamiento A/B, correlación trace/job y logs sin PII/secretos;
- [ ] F9.5 validada con gate estático, contrato DB y hardening adversarial T07/T10/T11/T16;
- [ ] F9.6 gate de release readiness verde sobre el informe final y runbook revisado;
- [ ] builds de plataformas declaradas como soportadas verdes;
- [ ] ninguna prueba crítica fallida;
- [ ] ninguna prueba crítica omitida;
- [ ] informe `FINAL_VALIDATION_REPORT.md` cerrado con `GO`.

---

# Resumen visual de ejecución

```text
T00  Preflight
  ↓
T01  Dependencias/workspace
  ↓
T02  Gates estáticos
  ↓
T03  Supabase local limpio
  ↓
T04  Schema + invariantes
  ↓
T05  Fixtures ORG_A / ORG_B
  ↓
T06  Bootstrap
  ↓
T07  RLS cross-tenant
  ↓
T08  Empleados / login
  ↓
T09  RPC
  ↓
T10  Edge Functions
  ↓
T11  Storage
  ↓
T12  Regresión del dominio
  ↓
T13  Flutter analyze/test
  ↓
T14  Integración / E2E
  ↓
T15  Builds + smoke
  ↓
T16  Seguridad
  ↓
T17  Performance
  ↓
T18  Segunda ejecución limpia
  ↓
T19  Informe final → GO / NO-GO
```

## Regla de mantenimiento

Cada fase nueva del roadmap debe revisar este mapa. Si introduce una superficie nueva —tabla, RPC, Edge Function, bucket, módulo, plataforma, suscripción, permiso o flujo— deberá incorporar su prueba al bloque T correspondiente **antes de que esa fase se marque como cerrada**.
