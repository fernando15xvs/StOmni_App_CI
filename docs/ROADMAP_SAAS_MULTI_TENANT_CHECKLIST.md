# Checklist — Roadmap SaaS Multi-Tenant StOmni

> Documento vivo. Marcar una fase cuando su implementación, gate específico y auditoría estén cerrados. La validación integral local de todo el producto se ejecuta al final mediante `docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md`; no se confunde un check de fase con el GO comercial final.

## Precondiciones ya cerradas

- [x] Refactor arquitectónico `core_logic` / mobile / desktop validado.
- [x] Proyecto Supabase de prueba `StOmniApp` operativo.
- [x] Baseline SQL reconstruido y validado en laboratorio.
- [x] Default privileges endurecidos.
- [x] Storage base creado y probado.
- [x] Edge Functions desplegadas con JWT.
- [x] Primer administrador de prueba creado.
- [x] Roadmap SaaS multi-tenant creado.
- [x] Rama `feature/saas-multitenant-foundation` creada.

---

## BLOQUE 0 — Preparación y mapa de impacto

- [x] Fase 0.1 — Inventario del modelo actual.
  - Auditoría: `docs/saas/00_FASE0_1_INVENTARIO_MODELO_ACTUAL.md`
  - Resultado: 62 tablas, 2 vistas, 176 funciones, 67 policies, 31 triggers y 21 Edge Functions inventariados; 0 policies tenant-aware y 0 tablas con `organization_id`.
- [x] Fase 0.2 — Contrato técnico de tenant.
  - Auditoría: `docs/saas/01_FASE0_2_CONTRATO_TECNICO_TENANT.md`
  - Resultado: congeladas las invariantes de `organizations`, `app_users`, separación Auth/empleado, UUID tenant, resolución server-side, FKs compuestas, unicidades por empresa, Storage y service-role tenant-aware.
- [x] Fase 0.3 — Gate de regresión y anti-singleton.
  - Auditoría: `docs/saas/02_FASE0_3_GATE_REGRESION_ANTI_SINGLETON.md`
  - Resultado: gate Node con baseline por blob SHA para deuda runtime legacy, bloqueo de nuevos singleton explícitos/implícitos y vigilancia de migraciones posteriores al baseline; self-test ampliado para aceptar sólo FKs legacy tenant-qualified.
- [x] **GATE BLOQUE 0 VERDE**

## BLOQUE 1 — Fundación multiempresa

- [x] Fase 1.1 — `organizations`.
  - Auditoría: `docs/saas/03_FASE1_1_ORGANIZATIONS.md`
  - Resultado: raíz tenant UUID, estados/región, timezone IANA, RLS cerrado, UUID inmutable y gate estático verde; compatibilidad PostgreSQL verificada read-only en laboratorio.
- [x] Fase 1.2 — `app_users` con una sola empresa por usuario.
  - Auditoría: `docs/saas/04_FASE1_2_APP_USERS.md`
  - Resultado: `user_id` PK enlazado a Auth, `organization_id` inmutable, estados/rol base restringidos, clave compuesta tenant-aware, RLS cerrado y gate de fundación ampliado.
- [x] Fase 1.3 — Separar `employees` de identidad/login.
  - Auditoría: `docs/saas/05_FASE1_3_EMPLOYEE_IDENTITY_SEPARATION.md`
  - Resultado: `empleados.organization_id`, login opcional mediante `app_user_id`, FK compuesta anti-cross-tenant, email de contacto único por empresa y transición controlada desde `auth_id` legacy; además se neutralizó el auto-enlace Auth→empleado por email global en `handle_new_user`/`vincular_usuario_empleado`.
- [x] Fase 1.4 — Bootstrap seguro de nueva empresa.
  - Auditoría: `docs/saas/06_FASE1_4_BOOTSTRAP_SEGURO_ORGANIZACION.md`
  - Resultado: bootstrap transaccional server-side sin parámetro `organization_id`; crea organization + admin + configuración + capabilities, elimina el constraint singleton de capabilities y prepara IDs no constantes para nuevas configuraciones. Gate específico versionado.
- [ ] **GATE BLOQUE 1 VERDE** — pendiente ejecutar en Supabase local T05/T06: dos organizaciones con admins distintos, doble-bootstrap rechazado y rollback sin huérfanos.

## BLOQUE 2 — Seguridad e aislamiento real

> Dependencia corregida: las tablas/RPC/Edge de dominio no podían quedar tenant-aware antes de recibir `organization_id`. F2.1/F2.2 cerraron la infraestructura y el patrón; Bloque 3 aplicó ese patrón por dominio. F2.3/F2.4 ya cierran la superficie estática global; F2.5 permanece como validación ofensiva dinámica.

- [x] Fase 2.1 — Helpers de autorización multi-tenant.
  - Auditoría: `docs/saas/07_FASE2_1_HELPERS_AUTORIZACION_MULTI_TENANT.md`
  - Resultado: tenant/rol/permisos derivados de `auth.uid()` mediante `app_users + organizations`; helpers privilegiados en schema `private`, `search_path=''`, permisos deny-by-default y gate específico versionado.
- [x] Fase 2.2 — RLS multi-tenant: patrón + fundación tenant-aware.
  - Auditoría: `docs/saas/08_FASE2_2_RLS_MULTI_TENANT_FUNDACION.md`
  - Resultado: policies tenant-aware y grants explícitos en fundación; el patrón fue aplicado a los dominios migrados en F3 y estructura profesional en F4.
- [x] Fase 2.3 — RPC tenant-aware.
  - Auditoría: `docs/saas/16_FASE2_3_RPC_TENANT_AWARE.md`
  - Resultado: gate global de superficie RPC sobre `apps/`, `packages/` y Edge; nombres dinámicos rechazados, `organization_id` manipulable bloqueado, motores legacy fuera de allowlist y gates de dominio integrados. Las reaperturas de Caja/personal sólo se permiten tras F4.3/F4.4.
- [x] Fase 2.4 — Edge Functions tenant-aware.
  - Auditoría: `docs/saas/17_FASE2_4_EDGE_FUNCTIONS_TENANT_AWARE.md`
  - Resultado: Edge Functions con JWT/contexto tenant derivado server-side, Storage tenant-namespaced y contratos service-role scopeados para fiscal/operaciones internas.
- [ ] Fase 2.5 — Suite de ataque cross-tenant.
  - Cierre dinámico en T07/T09/T10/T11 con ORG_A/ORG_B.
- [ ] **GATE BLOQUE 2 VERDE** — falta F2.5 y ejecución dinámica completa de aislamiento.

## BLOQUE 3 — Migración del dominio existente

- [x] Fase 3.1 — Configuración y capacidades por empresa.
  - Auditoría: `docs/saas/09_FASE3_1_CONFIGURACION_CAPACIDADES_POR_EMPRESA.md`
  - Resultado: backfill legacy a organization UUID, `organization_id NOT NULL`, RPC de configuración/capabilities tenant-aware, escritura sensible sólo por RPC, logos con prefijo tenant y singleton eliminado del runtime de este dominio.
- [x] Fase 3.2 — Clientes y proveedores por empresa.
  - Auditoría: `docs/saas/10_FASE3_2_CLIENTES_PROVEEDORES_POR_EMPRESA.md`
  - Resultado: ownership tenant explícito, backfill fail-closed, documento/RUC únicos por empresa, INSERT con tenant server-side, RLS tenant-aware y claves compuestas preparadas para FKs de dominios posteriores.
- [x] Fase 3.3 — Catálogo por empresa.
  - Auditoría: `docs/saas/11_FASE3_3_CATALOGO_POR_EMPRESA.md`
  - Resultado: 7 tablas de catálogo con tenant directo, SKU único por empresa, FKs compuestas, RLS, RPC de catálogo tenant-aware, imágenes namespaced y evaluación/eliminación protegidas por wrapper tenant.
- [x] Fase 3.4 — Almacenes e inventario por empresa.
  - Auditoría: `docs/saas/12_FASE3_4_ALMACENES_INVENTARIO_POR_EMPRESA.md`
  - Resultado: 11 tablas de inventario tenant-qualified, FKs producto/almacén compuestas, RLS, idempotencia por tenant, RPC activos protegidos, RPC legacy revocados y escritura directa de saldo retirada del runtime Flutter.
- [x] Fase 3.5 — Ventas, cotizaciones y pagos por empresa.
  - Auditoría: `docs/saas/13_FASE3_5_VENTAS_COTIZACIONES_PAGOS_POR_EMPRESA.md`
  - Resultado: ventas/cotizaciones/pagos y constancias de descuento tenant-qualified, FKs compuestas y RLS; entrypoints runtime validados por tenant, motores legacy internos scopeados y sin EXECUTE cliente.
- [x] Fase 3.6 — Compras por empresa.
  - Auditoría: `docs/saas/14_FASE3_6_COMPRAS_POR_EMPRESA.md`
  - Resultado: órdenes, líneas, recepciones, gastos y pagos a proveedor tenant-qualified; FKs e idempotencia por empresa; singleton `business_id=1` eliminado del guard de compras; RPC activos scopeados.
- [x] Fase 3.7 — Fiscal y documentos electrónicos por empresa.
  - Auditoría: `docs/saas/15_FASE3_7_FISCAL_DOCUMENTOS_POR_EMPRESA.md`
  - Resultado: 19 tablas fiscales/GRE tenant-owned; correlativos, series y request IDs por empresa; FKs/RLS/RPC/Edge tenant-aware; `service_role` scopeado por header interno derivado server-side; identidad fiscal alineada con `app_users`; Storage nuevo bajo `<organization_id>/...`.
- [ ] **GATE BLOQUE 3 VERDE** — implementación F3.1–F3.7 completa; pendiente T03/T07/T09/T10/T11/T12 con `supabase db reset`, pgTAP y escenarios reales ORG_A/ORG_B.

## BLOQUE 4 — Estructura profesional de cada empresa

- [x] Fase 4.1 — Sucursales.
  - Auditoría: `docs/saas/18_FASE4_1_SUCURSALES.md`
  - Resultado: `branches` tenant-owned, sucursal principal automática, código único por empresa, RLS y mutaciones sólo por RPC `tenant.admin`.
- [x] Fase 4.2 — Almacenes por sucursal.
  - Auditoría: `docs/saas/19_FASE4_2_ALMACENES_POR_SUCURSAL.md`
  - Resultado: `almacenes.branch_id NOT NULL`, FK compuesta tenant-safe, backfill/default a principal y protección contra desactivar una sucursal con almacenes activos.
- [x] Fase 4.3 — Cajas/puntos de operación.
  - Auditoría: `docs/saas/20_FASE4_3_CAJAS_PUNTOS_OPERACION.md`
  - Resultado: `cash_registers` por sucursal, sesiones tenant/register-aware, una sesión abierta por caja y usuario, pagos venta/gasto por `cash_session_id`, vistas `security_invoker` y deuda/gasto cash sin motor global.
- [x] Fase 4.4 — Empleados por empresa.
  - Auditoría: `docs/saas/21_FASE4_4_EMPLEADOS_POR_EMPRESA.md`
  - Resultado: ficha laboral con tenant+sucursal+estado y login opcional; pagos de personal tenant/cash-aware, eliminación por RPC segura y Caja consolidada por sesión.
- [x] Fase 4.5 — Roles y permisos configurables.
  - Auditoría: `docs/saas/22_FASE4_5_ROLES_PERMISOS_CONFIGURABLES.md`
  - Resultado: `permissions`, `roles`, `role_permissions`, `employee_roles` y overrides por tenant; `app_tiene_permiso` usa RBAC configurable manteniendo compatibilidad JSON con Flutter.
- [ ] **GATE BLOQUE 4 VERDE** — implementación F4.1–F4.5 completa; pendiente `db reset`, pgTAP y escenarios ORG_A/ORG_B/multisucursal en T03/T04/T07/T09/T12/T14.

## BLOQUE 5 — StOmni adaptable a distintos rubros

- [x] Fase 5.1 — Capacidades por empresa.
  - Auditoría: `docs/saas/23_FASE5_1_CAPACIDADES_POR_EMPRESA.md`
  - Resultado: capacidades persistidas por tenant con invariantes y enforcement backend para inventario, sucursales, almacenes, compras y trazabilidad.
- [x] Fase 5.2 — Catálogo genérico.
  - Auditoría: `docs/saas/24_FASE5_2_CATALOGO_GENERICO.md`
  - Resultado: `item_type` explícito (`stock_product`, `non_stock_product`, `service`, `bundle`), bundles tenant-safe con snapshot/reversión y caché offline compatible.
- [x] Fase 5.3 — Campos y reglas configurables.
  - Auditoría: `docs/saas/25_FASE5_3_CAMPOS_REGLAS_CONFIGURABLES.md`
  - Resultado: definiciones tipadas tenant-owned + `custom_fields` JSONB validado en catálogo/clientes/proveedores, sin EAV ni reglas ejecutables arbitrarias.
- [x] Fase 5.4 — UI dinámica por módulos.
  - Auditoría: `docs/saas/26_FASE5_4_UI_DINAMICA_MODULOS.md`
  - Resultado: `BusinessModulePolicy` compartida, navegación capability-driven mobile/desktop y configuración de módulos siempre recuperable por admin.
- [ ] **GATE BLOQUE 5 VERDE** — implementación F5.1–F5.4 completa y gate maestro `scripts/verify_saas_adaptability_block.mjs` versionado; pendiente ejecución dinámica T02/T03/T04/T09/T12/T13/T14/T15.

## BLOQUE 6 — Auditoría, automatización y analítica

- [x] Fase 6.1 — Auditoría empresarial.
  - Auditoría: `docs/saas/27_FASE6_1_AUDITORIA_EMPRESARIAL.md`
  - Resultado: ledger `audit_logs` append-only, tenant-aware y de metadata allowlisted; cubre precios, stock sensible, anulaciones, descuentos, permisos y configuración; lectura sólo por RPC administrativo.
- [x] Fase 6.2 — Alertas y automatizaciones.
  - Auditoría: `docs/saas/28_FASE6_2_ALERTAS_AUTOMATIZACIONES.md`
  - Resultado: inbox `operational_alerts` por tenant para stock bajo, vencimientos, deuda antigua, compras pendientes, cajas abiertas y tareas; settings con revision; push OneSignal global legacy retirado.
- [x] Fase 6.3 — Dashboard configurable.
  - Auditoría: `docs/saas/29_FASE6_3_DASHBOARD_CONFIGURABLE.md`
  - Resultado: `business_metric_definitions` deja `business_id=1`, pasa a `organization_id`; KPIs server-side por periodo/sucursal con margen/rotación fail-closed y UI mobile/desktop alineada.
- [x] Fase 6.4 — Asistente empresarial StOmni.
  - Auditoría: `docs/saas/30_FASE6_4_ASISTENTE_EMPRESARIAL.md`
  - Resultado: frontera segura de contexto con cuatro intenciones allowlisted, opt-in por tenant, sin SQL libre/service-role global y con settings auditados; preparada para integrar proveedor IA desacoplado después.
- [ ] **GATE BLOQUE 6 VERDE** — implementación F6.1–F6.4 completa y gate maestro `scripts/verify_saas_intelligence_block.mjs` versionado; pendiente ejecución dinámica T02/T03/T07/T09/T12/T13/T14.

## BLOQUE 7 — Suscripciones y monetización

- [x] Fase 7.1 — Catálogo de planes.
  - Auditoría: `docs/saas/31_FASE7_1_CATALOGO_PLANES.md`
  - Resultado: catálogo global read-only `starter/business/pro/enterprise`, con identidad estable y sin precios/IDs de proveedor inventados.
- [x] Fase 7.2 — Suscripción por empresa.
  - Auditoría: `docs/saas/32_FASE7_2_SUSCRIPCION_POR_EMPRESA.md`
  - Resultado: una suscripción tenant-owned por organización, estados/revision y writer únicamente backend; rollout compatible con Enterprise temporal.
- [x] Fase 7.3 — Entitlements y límites.
  - Auditoría: `docs/saas/33_FASE7_3_ENTITLEMENTS_LIMITES.md`
  - Resultado: catálogo tipado de features/límites por plan, helpers backend y seed neutral sin packaging comercial inventado.
- [x] Fase 7.4 — Enforcement backend.
  - Auditoría: `docs/saas/34_FASE7_4_ENFORCEMENT_BACKEND.md`
  - Resultado: capabilities, usuarios, sucursales, almacenes, cajas, analytics y asistente quedan limitados server-side; downgrades incompatibles fallan.
- [x] Fase 7.5 — Interfaz para proveedor de pagos.
  - Auditoría: `docs/saas/35_FASE7_5_INTERFAZ_PROVEEDOR_PAGOS.md`
  - Resultado: interfaz provider-agnostic con mapping price->plan, bindings privados, webhooks idempotentes sin payload bruto y wrapper sólo service_role.
- [ ] **GATE BLOQUE 7 VERDE** — implementación F7.1–F7.5 completa y gate maestro `scripts/verify_saas_billing_block.mjs` versionado; pendiente T02/T03/T04/T07/T09/T10/T14/T17 y pruebas del proveedor concreto cuando se seleccione.

## BLOQUE 8 — Experiencia SaaS y onboarding

- [x] Fase 8.1 — Alta de empresa.
  - Auditoría: `docs/saas/36_FASE8_1_ALTA_EMPRESA.md`
  - Resultado: frontera autoservicio pre-tenant, bootstrap técnico F1.4 cerrado al cliente, alta sin `organization_id/plan_code` manipulables y nuevas empresas en identidad Starter server-side.
- [x] Fase 8.2 — Configuración guiada.
  - Auditoría: `docs/saas/37_FASE8_2_CONFIGURACION_GUIADA.md`
  - Resultado: state machine tenant-owned y secuencial con optimistic concurrency, progreso UX separado de las fuentes autoritativas y tenants existentes grandfathered como completados.
- [x] Fase 8.3 — UX mobile / desktop / web.
  - Auditoría: `docs/saas/38_FASE8_3_UX_MOBILE_DESKTOP_WEB.md`
  - Resultado: política de routing compartida, alta/configuración responsive en mobile-Web y flujos desktop equivalentes; pre-tenant fuera de autorización/offline, revalidación online posterior al alta y cache de onboarding aislado entre sesiones.
- [x] Fase 8.4 — Branding por empresa.
  - Auditoría: `docs/saas/39_FASE8_4_BRANDING_EMPRESA.md`
  - Resultado: `configuracion_negocio` sigue siendo la fuente autoritativa; nombre/logo tenant-aware compartidos por mobile-Web, Desktop y PDFs, con caché visual aislada y limpieza del perfil fiscal entre sesiones.
- [ ] **GATE BLOQUE 8 VERDE**

## BLOQUE 9 — Hardening y salida comercial

- [x] Fase 9.1 — E2E multiempresa.
  - Auditoría: `docs/saas/40_FASE9_1_E2E_MULTIEMPRESA.md`
  - Resultado: runner E2E local-only con ORG_A/ORG_B reales, alta/onboarding en paralelo, CRUD de cliente con JWT `authenticated` y ataques SELECT/UPDATE/DELETE/spoof cross-tenant; ejecución dinámica reservada para T14/T18.
- [x] Fase 9.2 — Carga y concurrencia.
  - Auditoría: `docs/saas/41_FASE9_2_CARGA_CONCURRENCIA.md`
  - Resultado: idempotencia de inventario terminada en namespace `(organization_id,request_id)`, contrato pgTAP de 19 assertions para locks/índices/correlativos y probe local ORG_A/ORG_B con contención exactly-once y p50/p95/p99; certificación dinámica reservada para T17/T18.
- [x] Fase 9.3 — Backups y recuperación.
  - Auditoría: `docs/saas/42_FASE9_3_BACKUPS_RECUPERACION.md`
  - Política: `docs/saas/BACKUP_RECOVERY_POLICY.md`
  - Resultado: snapshot local de `public` + identidad Auth, bytes Storage con SHA-256, restore drill destructivo sólo loopback/opt-in, fingerprints exactos y export tenant sin credenciales; recuperación dinámica reservada para T18/T19.
- [x] **Fase 9.4 — Observabilidad**
  - [x] Configurar logs y métricas.
  - [x] Definir filtros por tenant para soporte.
  - [x] Evitar PII innecesaria en logs.
  - [x] Definir alertas de servicio.
  - Auditoría: `docs/saas/43_FASE9_4_OBSERVABILIDAD.md`
  - Gate: `scripts/verify_saas_observability.mjs`
  - Contrato DB: `supabase/tests/database/observability_contract_test.sql`
  - Resultado: 21 Edge Functions bajo `serveObserved`, `trace_id` correlacionable sin confiar tenant del cliente, seis jobs con `job_id`, ledger service-role-only, métricas/errores tenant-admin, redacción de consola y alertas operativas/release-blocking; validación dinámica reservada para T02/T04/T16/T19.
- [x] Fase 9.5 — Seguridad final.
  - Auditoría: `docs/saas/44_FASE9_5_SEGURIDAD_FINAL.md`
  - Gate: `scripts/verify_saas_final_security.mjs`
  - Contrato DB: `supabase/tests/database/final_security_contract_test.sql`
  - Resultado: higiene de archivos versionados/secretos y frontera Flutter-backend congeladas; privilegios críticos de `private`, RLS, ledgers y writer de observabilidad bajo contrato; ataques reales A/B, Edge y Storage reservados para T07/T10/T11/T16/T19.
- [x] Fase 9.6 — Release comercial.
  - Auditoría: `docs/saas/45_FASE9_6_RELEASE_COMERCIAL.md`
  - Runbook: `docs/saas/RELEASE_RUNBOOK.md`
  - Plantilla T19: `docs/saas/FINAL_VALIDATION_REPORT_TEMPLATE.md`
  - Gate: `scripts/verify_saas_release_readiness.mjs`
  - Resultado: proceso de release, rollback y evidencia final versionados; un `GO` documental incompleto queda bloqueado y el despliegue real sigue prohibido hasta T00–T19 + `FINAL_VALIDATION_REPORT.md` con GO.
- [ ] **GATE BLOQUE 9 VERDE** — todas las fases F9.1–F9.6 están implementadas; pendiente validación dinámica final T00–T19.

---

## VALIDACIÓN FINAL LOCAL — ejecutar cuando el roadmap de implementación esté cerrado

Mapa maestro: `docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md`

- [x] Mapa T00–T19 definido y versionado.
- [ ] T00 — Preflight/toolchain.
- [ ] T01 — Dependencias/workspace.
- [ ] T02 — Gates estáticos SaaS.
- [ ] T03 — Supabase local desde cero.
- [ ] T04 — Schema e invariantes.
- [ ] T05 — Fixtures ORG_A/ORG_B.
- [ ] T06 — Bootstrap transaccional.
- [ ] T07 — Matriz RLS cross-tenant.
- [ ] T08 — Empleados vs login.
- [ ] T09 — RPC tenant-aware.
- [ ] T10 — Edge Functions/service_role.
- [ ] T11 — Storage multi-tenant.
- [ ] T12 — Regresión dominio.
- [ ] T13 — `flutter analyze` + `flutter test`.
- [ ] T14 — Integración/E2E.
- [ ] T15 — Builds y smoke por plataforma soportada.
- [ ] T16 — Hardening de seguridad.
- [ ] T17 — Performance/planes tenant-aware.
- [ ] T18 — Segunda ejecución limpia completa.
- [ ] T19 — `docs/saas/FINAL_VALIDATION_REPORT.md` con decisión GO.
- [ ] Cero pruebas críticas fallidas.
- [ ] Cero pruebas críticas omitidas.

## Estado global

- [ ] Multi-tenant backend completo.
- [ ] Aislamiento cross-tenant probado.
- [x] Dominio existente migrado a nivel de implementación.
- [x] Configuración por empresa completa a nivel de implementación.
- [x] Módulos adaptables por rubro a nivel de implementación.
- [x] Suscripciones listas a nivel de implementación provider-agnostic.
- [x] Onboarding autoservicio listo a nivel de implementación — F8.1–F8.4 cerradas; certificación dinámica pendiente.
- [x] Backup/restore/export SaaS listos a nivel de implementación — restore drill T18 y política RPO/RTO final T19 pendientes.
- [x] Observabilidad SaaS lista a nivel de implementación — correlación/aislamiento/log hygiene pendientes de T02/T04/T16/T19.
- [x] Roadmap SaaS completo a nivel de implementación — F0–F9.6 versionadas; validación integral T00–T19 pendiente.
- [ ] Mobile / desktop / web listos — implementación F8.3/F8.4 completa; T13–T15 pendientes.
- [ ] Seguridad y hardening final verdes — implementación F9.5 completa; validación dinámica T02/T04/T07/T10/T11/T16/T19 pendiente.
- [ ] StOmni listo para comercialización SaaS.

## Regla de actualización

Cada vez que se cierre una fase:
1. marcar el checkbox correspondiente;
2. registrar commit/resultado del gate de fase en su auditoría;
3. actualizar `99_MAPA_MAESTRO_PRUEBAS_SAAS.md` si la fase introduce una nueva superficie a probar;
4. no marcar el gate del bloque hasta que todas sus fases estén verdes;
5. no declarar GO final hasta ejecutar T00–T19 sobre el commit candidato definitivo.