# Fase 3.7 — Fiscal y documentos electrónicos por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

F3.7 cierra a nivel de implementación el dominio fiscal multi-tenant de StOmni. No se aplicó DDL al proyecto Supabase remoto y la rama `feature/saas-multitenant-foundation` continúa fuera de los triggers de GitHub Actions.

Migraciones de la fase:

- `supabase/migrations/20260908022900_saas_uuid_min_compat.sql`
- `supabase/migrations/20260908023000_saas_fiscal_tenant_schema.sql`
- `supabase/migrations/20260908023010_saas_uuid_min_compat_cleanup.sql`
- `supabase/migrations/20260908024000_saas_fiscal_rpc_guards.sql`
- `supabase/migrations/20260908024500_saas_fiscal_internal_rpc_scope.sql`
- `supabase/migrations/20260908024550_saas_fiscal_app_user_identity.sql`
- `supabase/migrations/20260908024600_saas_fiscal_storage_paths.sql`
- `supabase/migrations/20260908024700_saas_new_tenant_fiscal_default.sql`

Gate estructural:

- `scripts/verify_saas_fiscal.mjs`

Contrato pgTAP:

- `supabase/tests/database/fiscal_tenant_contract_test.sql`

## Superficie migrada

F3.7 convierte en tenant-owned 19 tablas fiscales/GRE:

1. `series_comprobantes`
2. `comprobantes_electronicos`
3. `facturacion_intentos`
4. `notas_credito`
5. `notas_credito_detalles`
6. `notas_credito_intentos`
7. `gre_transportistas`
8. `gre_transportistas_agencias`
9. `gre_conductores`
10. `gre_vehiculos`
11. `guias_remision`
12. `guias_remision_detalles`
13. `guias_remision_intentos`
14. `solicitudes_baja_tributaria`
15. `procesos_tributarios`
16. `procesos_tributarios_detalles`
17. `procesos_tributarios_intentos`
18. `correlativos_procesos_tributarios`
19. `documentos_tributarios_reconciliaciones`

`gre_ubigeos` permanece global/read-only porque es un catálogo geográfico nacional y no pertenece a una empresa concreta.

## Backfill fail-closed

El ownership histórico se deriva primero desde dominios ya tenant-aware:

- comprobante -> venta;
- intento -> comprobante;
- nota -> comprobante/venta;
- detalle/intento NC -> nota;
- solicitud de baja -> comprobante/nota/venta;
- proceso tributario -> solicitudes/detalles;
- GRE -> venta/comprobante/transferencia;
- detalles/intentos GRE -> cabecera;
- catálogos de transporte -> referencias históricas cuando el ownership es unívoco.

Sólo las filas legacy sin una relación resoluble pueden usar fallback, y únicamente cuando existe exactamente una organización de negocio. Un estado ambiguo aborta la migración.

Después del backfill, las 19 tablas reciben `organization_id NOT NULL`.

## Correlativos y namespaces independientes

Las restricciones globales pasan a incluir organización.

Ejemplos:

- serie fiscal: `(organization_id, tipo_documento_sunat, serie)`;
- comprobante: `(organization_id, tipo_documento_sunat, serie, correlativo)`;
- nota: `(organization_id, serie, correlativo)`;
- GRE: `(organization_id, tipo_documento_sunat, serie, correlativo)`;
- proceso tributario: `(organization_id, tipo_proceso, fecha_referencia, correlativo)`;
- correlativo de proceso: PK `(organization_id, tipo_proceso, fecha_referencia)`;
- `request_id` de comprobante, NC, GRE, baja y proceso es único dentro de la empresa, no globalmente.

Por tanto ORG_A y ORG_B pueden usar las mismas series, correlativos o UUID de idempotencia sin compartir estado.

## Relaciones tenant-qualified

Las relaciones fiscales principales incorporan `organization_id` en ambos lados, por ejemplo:

- comprobante -> venta;
- intento -> comprobante;
- nota -> comprobante/venta;
- detalle nota -> nota/producto/almacén/detalle de venta;
- GRE -> venta/transferencia/comprobante/catálogos de transporte;
- detalle GRE -> GRE/producto/almacén/venta/transferencia;
- proceso tributario -> solicitud/comprobante/nota/venta.

Un ID válido de otra empresa no puede formar una FK válida con el tenant actual.

## RLS y Data API

Las 19 tablas tienen RLS habilitado.

La lectura operativa usa `private.row_belongs_to_current_organization(organization_id)` y permisos del tenant. Las tablas de auditoría/intentos/procesos exigen privilegio administrativo cuando corresponde.

Las mutaciones fiscales sensibles siguen canalizadas por RPC/Edge Functions; no se abre una escritura directa amplia a `authenticated`.

Los catálogos GRE que sí necesita editar Flutter conservan CRUD controlado por RLS tenant-aware.

## Facturación electrónica reabierta

F3.5 mantenía `boleta` y `factura` bloqueadas de forma deliberada hasta que series y comprobantes dejaran de ser globales.

F3.7 scopea dentro de `process_sale_v3`:

- la selección de serie;
- el incremento del correlativo;
- el replay del comprobante de una venta;
- la relación con la venta del tenant.

Después de ese hardening, `process_sale_v4` y `process_sale_with_units_v4` vuelven a aceptar:

- `ticket_interno`;
- `boleta`;
- `factura`.

El antiguo mensaje `Electronic invoicing is temporarily disabled until fiscal tenant rollout F3.7` deja de ser una barrera runtime.

## Notas de crédito

`crear_nota_credito_with_units_v3` valida el comprobante y los detalles dentro del tenant antes de entrar al motor histórico.

El motor interno queda scopeado en:

- replay por `request_id`;
- comprobante origen;
- venta origen;
- notas ya comprometidas;
- serie/correlativo de NC.

Las versiones internas/legacy continúan fuera de la superficie cliente.

## GRE

`guardar_guia_remision_v4` valida server-side que pertenecen al tenant actual:

- guía editada;
- venta;
- transferencia;
- GRE remitente vinculada;
- transportista;
- conductor;
- vehículo;
- transportista/agencias de transbordo;
- productos, detalles de venta y almacenes del payload.

El motor v3 scopea replay, edición, configuración y series. `eliminar_borrador_guia_v1` también opera exclusivamente sobre la organización autenticada.

## Bajas y procesos tributarios

`solicitar_baja_tributaria_v1` scopea:

- idempotencia;
- comprobante/nota origen;
- notas activas relacionadas;
- actualización del documento origen.

`listar_documentos_electronicos_v1` fue reconstruida para unir solamente comprobantes, notas y GRE de la organización actual.

`tributario_preparar_procesos` usa el tenant dentro de:

- selección de solicitudes pendientes;
- advisory lock;
- correlativo;
- proceso;
- detalles;
- actualización de solicitudes y documentos.

El procesamiento tributario automático continúa deliberadamente deshabilitado; no se introdujo un job global que pueda procesar tenants sin contexto explícito.

## Edge Functions y `service_role`

`service_role` bypasssea RLS, por lo que F3.7 no confía en RLS para proteger los Edge Functions.

`auth_guard.ts` ahora:

1. valida el JWT;
2. resuelve `auth user -> app_users -> organization`;
3. exige usuario y organización activos;
4. toma el rol desde `app_users.base_role`;
5. exige empleado activo vinculado dentro del mismo tenant;
6. crea un cliente `service_role` tenant-scoped;
7. inyecta `organization_id=eq.<tenant>` en consultas Data API a tablas empresariales;
8. envía `x-stomni-organization-id` a los RPC internos.

Los endpoints individuales de comprobantes, NC, GRE y procesos hacen además un precheck del recurso dentro del tenant antes de entrar al helper privilegiado.

Los batch de reintentos filtran la organización desde la consulta candidata, por lo que ni siquiera enumeran trabajo pendiente de otra empresa.

## RPC internos `service_role`

Los claims/finalizadores de:

- comprobantes;
- notas de crédito;
- GRE;
- procesos tributarios;

requieren un tenant interno validado por PostgreSQL.

Los inserts de intentos escriben `organization_id` explícitamente. Los RPC internos permanecen revocados para `PUBLIC`, `anon` y `authenticated`, y sólo conservan `EXECUTE` para `service_role` cuando corresponde.

Una validación read-only contra PostgreSQL 17.6 confirmó que los fragmentos deterministas esperados estaban presentes en las 8 funciones internas antes de aplicar los parches de la rama.

## Identidad `app_users` vs `employees`

F3.7 corrige la deuda conceptual de funciones fiscales que todavía verificaban únicamente `empleados.auth_id`.

El contrato final es:

- `app_users` / `base_role`: autoridad de acceso;
- `employees`: vínculo laboral activo;
- `app_user_id`: vínculo canónico;
- `auth_id`: fallback transitorio para filas históricas.

`_gre_empleado_activo`, NC, bajas y los claims internos dejan de depender exclusivamente de `auth_id`.

## Storage fiscal

El bucket `comprobantes-electronicos` continúa privado.

Para documentos nuevos, el cliente Edge tenant-scoped reescribe la escritura física a:

```text
<organization_id>/<ruta-fiscal-existente>
```

PostgreSQL normaliza también `xml_path`, `pdf_path` y `cdr_path` de:

- comprobantes;
- notas;
- GRE;
- procesos tributarios.

Los archivos legacy existentes **no se mueven ni se reescriben** en esta migración. Las operaciones de firma/lectura conservan su ruta histórica, evitando romper XML/PDF/CDR ya almacenados. Los paths nuevos sí quedan persistidos con el UUID del tenant como primer segmento.

## Compatibilidad PostgreSQL 17 — `min(uuid)`

La migración fiscal usa `min(organization_id)` durante backfills unívocos. PostgreSQL 17.6 no expone `min(uuid)` de forma nativa.

Se añadió una compatibilidad temporal antes del schema fiscal y se elimina inmediatamente después. El agregado auxiliar no permanece en el esquema final.

Este fallo fue detectado antes de marcar F3.7 como cerrada; sin la corrección, un `supabase db reset` se habría detenido durante el backfill.

## Nuevas organizaciones: facturación fail-closed

El schema legacy tenía `business_capabilities.electronic_invoicing DEFAULT true`.

Una empresa recién creada por `bootstrap_organization_v1` todavía no tiene por qué disponer de series/configuración SUNAT propias. F3.7 cambia **sólo el default futuro** a `false`.

- no modifica la capacidad actual de la empresa legacy;
- una nueva organización no anuncia facturación electrónica antes de configurarla;
- el onboarding posterior podrá habilitarla explícitamente.

No se inventan series ni correlativos legales automáticamente.

## Deuda sintáctica legacy congelada

El gate anti-singleton general todavía congela por SHA tres superficies antiguas:

- `packages/core_logic/lib/features/facturacion/data/guias_remision_repository.dart`;
- `supabase/functions/_shared/proceso_tributario_common.ts`;
- `supabase/functions/_shared/guia_remision_common.ts`.

Estas referencias ya no son autoridad de tenant:

- Flutter queda limitado por RLS antes de cualquier `order/limit`;
- el cliente Edge `service_role` inyecta siempre `organization_id`;
- el antiguo `.eq('id', 1)` de configuración se neutraliza únicamente después de resolver el tenant server-side;
- un cambio en esos archivos continúa fallando el anti-singleton gate mientras contenga el patrón legacy.

Su limpieza textual puede hacerse después sin cambiar el modelo de seguridad. No se considera una autorización singleton activa.

## Verificaciones versionadas

`scripts/verify_saas_fiscal.mjs` comprueba estructuralmente, entre otros puntos:

- 19 tablas tenant-owned;
- backfill/enforcement/RLS;
- namespaces de series/correlativos/request IDs;
- FKs compuestas;
- RPC públicos tenant-aware;
- reapertura controlada de boleta/factura;
- hardening de RPC `service_role`;
- ausencia del `%n` inválido detectado durante la auditoría;
- Edge tenant-scoped;
- batch por empresa;
- namespace Storage.

`fiscal_tenant_contract_test.sql` contiene 39 assertions pgTAP sobre el esquema resultante, constraints, policies, funciones y permisos.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| perfil fiscal por empresa | ✅ |
| 19 tablas fiscales/GRE con `organization_id NOT NULL` | ✅ en migración |
| backfill fail-closed | ✅ |
| series/correlativos independientes | ✅ |
| request IDs por tenant | ✅ |
| FKs críticas tenant-qualified | ✅ |
| RLS tenant-aware | ✅ en migración |
| comprobantes/NC/GRE aislados | ✅ en código |
| boleta/factura reabiertas después del hardening | ✅ |
| Edge Functions resuelven tenant server-side | ✅ |
| `service_role` no depende de RLS | ✅ |
| identidad canónica `app_user_id` | ✅ |
| Storage nuevo bajo prefijo de organización | ✅ |
| nueva organización inicia facturación electrónica deshabilitada | ✅ |
| gate estructural versionado | ✅ |
| pgTAP fiscal versionado | ✅ 39 checks |
| validación de fragmentos PostgreSQL 17.6 | ✅ read-only |
| `supabase db reset` completo | ⏳ T03/T18 |
| pgTAP ejecutado sobre DB reseteada | ⏳ T03/T07 |
| ORG_A vs ORG_B real para fiscal/RPC/Storage | ⏳ T07/T10/T11/T12 |
| Flutter analyze/test completo | ⏳ T13 |

## Resultado

F3.7 queda **cerrada a nivel de implementación**. El dominio fiscal ya tiene ownership, correlativos, relaciones, RPC, Edge Functions y Storage preparados para múltiples organizaciones sin confiar en un tenant enviado por Flutter.

El **Gate del Bloque 3 no se marca todavía como verde**: requiere ejecutar el `db reset`, pgTAP y los escenarios dinámicos ORG_A/ORG_B sobre el commit candidato antes de avanzar formalmente al Bloque 4.
