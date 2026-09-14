# Fase 9.4 — Observabilidad

## Estado

**IMPLEMENTADA / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

F9.4 incorpora una frontera única de observabilidad para las Edge Functions SaaS de StOmni sin convertir los logs en un canal secundario de PII o secretos.

La fase deja versionados:

- ledger técnico: `public.observability_events`;
- writer interno: `record_observability_event_v1`;
- métricas tenant-safe: `get_observability_metrics_v1`;
- errores recientes tenant-safe: `list_recent_observability_errors_v1`;
- wrapper Edge: `supabase/functions/_shared/observability.ts`;
- enlace de tenant desde `auth_guard.ts`;
- instrumentación de los 21 entrypoints HTTP existentes;
- `job_id` para seis operaciones batch/manuales;
- contrato pgTAP: `supabase/tests/database/observability_contract_test.sql`;
- gate estático: `scripts/verify_saas_observability.mjs`.

No se ejecutó GitHub Actions, no se aplicó la migración al Supabase remoto y no se declara todavía ninguna prueba dinámica de observabilidad como verde.

## 1. Contrato de trace

Cada request observado recibe un `trace_id` UUID.

- si el cliente envía `x-stomni-trace-id` y es un UUID válido, se conserva para correlación;
- cualquier valor no UUID se descarta y se genera `crypto.randomUUID()`;
- la respuesta devuelve `x-stomni-trace-id`;
- el evento persistido usa el mismo UUID;
- el trace aportado por cliente **no puede aportar ni modificar `organization_id`**.

El tenant se enlaza sólo después de que `requireEmployee()` resuelva server-side:

```text
auth token -> auth.users -> app_users -> organizations
```

Por tanto, un atacante puede proponer un identificador de correlación, pero no adjudicar ese trace a otra empresa.

## 2. Ledger técnico mínimo

`observability_events` almacena exclusivamente:

- `organization_id` nullable para eventos de plataforma previos a tenant;
- `trace_id`;
- `job_id` opcional;
- componente;
- nombre técnico de evento;
- severidad;
- outcome;
- duración;
- estado HTTP;
- código técnico de error;
- timestamp.

Deliberadamente **no existen** columnas libres para:

- request/response body;
- payload o metadata arbitraria;
- mensaje crudo de excepción;
- email;
- DNI/RUC/documento;
- nombres;
- tokens/JWT;
- Authorization/Cookie;
- secretos.

La firma de `record_observability_event_v1` tampoco acepta esos datos. La prevención de PII se aplica en el contrato de persistencia y no sólo por convención del programador.

## 3. Escritura y acceso

El ledger crudo queda cerrado a `anon` y `authenticated`.

`record_observability_event_v1`:

- es `SECURITY DEFINER` con `search_path=''`;
- revoca `EXECUTE` a `PUBLIC`, `anon` y `authenticated`;
- concede `EXECUTE` únicamente a `service_role`;
- rechaza tenants inexistentes;
- valida regex/rangos de todos los campos técnicos.

La autorización del writer se controla por privilegios PostgreSQL de `EXECUTE`, no mediante `current_user` dentro del `SECURITY DEFINER`. Esto es deliberado: durante la ejecución de una función `SECURITY DEFINER`, `current_user` corresponde al propietario de la función y no al rol invocador, por lo que usarlo para comprobar `service_role` bloquearía llamadas legítimas.

Los usuarios normales no consultan el ledger.

Un administrador de tenant puede consumir únicamente RPC agregadas/sanitizadas:

- `get_observability_metrics_v1(1..168 horas)`;
- `list_recent_observability_errors_v1(1..100 filas)`.

Ambas derivan `organization_id` del contexto autenticado, exigen `tenant.admin` y filtran `organization_id=v_org` dentro de PostgreSQL.

## 4. Métricas

La RPC de métricas devuelve por tenant:

- eventos totales;
- succeeded;
- failed;
- denied;
- p50;
- p95;
- p99;
- conteos por componente.

F9.4 **no inventa un SLO comercial**. Los percentiles son evidencia para fijar objetivos posteriores; no constituyen por sí solos un SLA/SLO prometido al cliente.

## 5. Jobs

Las siguientes operaciones se tratan además como jobs y generan un `job_id` UUID por ejecución:

1. `ejecutar-resumen-diario`;
2. `procesar-bajas-tributarias`;
3. `reintentar-comprobantes-pendientes`;
4. `reintentar-guias-pendientes`;
5. `reintentar-notas-credito-pendientes`;
6. `reintentar-procesos-tributarios-pendientes`.

El `job_id` se vincula al mismo evento de request y se devuelve en la respuesta para soporte/correlación.

Los jobs de pendientes no se consideran automáticamente exitosos por responder HTTP 200:

- sin candidatos -> `skipped`;
- uno o más fallos internos -> `failed / BATCH_PARTIAL_FAILURE`;
- procesamiento sin fallos -> `succeeded`.

Esto evita ocultar fallos parciales bajo una métrica HTTP superficial.

## 6. Redacción de consola

Algunos helpers fiscales legacy todavía emiten `console.error(label, error)`.

Reescribirlos todos durante F9.4 aumentaría el radio de cambio sobre lógica fiscal ya estabilizada. En su lugar, `observability.ts` instala un guard común antes de ejecutar los handlers observados.

El guard:

- conserva los eventos JSON técnicos allowlisted de StOmni;
- redacta Bearer tokens;
- redacta patrones JWT;
- redacta emails;
- redacta URLs completas;
- redacta secuencias numéricas largas compatibles con documentos/teléfonos;
- limita strings no estructurados;
- convierte `Error` a `name/code` sanitizados;
- sustituye objetos arbitrarios de SDK/provider por `[redacted-object]`.

Como el gate exige que **cada entrypoint** use `serveObserved`, una nueva Edge Function que omita esta frontera debe hacer fallar T02.

`get-persona` fue además saneada directamente porque manejaba DNI/RUC y respuestas de proveedor: sus logs técnicos ya no serializan documento, payload del proveedor ni error crudo.

## 7. Fail-open controlado

La telemetría no es parte de la transacción de negocio.

Si falla la persistencia del evento:

- la operación original conserva su respuesta;
- se emite un evento interno mínimo `OBSERVABILITY_PERSIST_FAILED`;
- nunca se serializa el error del SDK al log.

Esto evita que una indisponibilidad de observabilidad bloquee ventas, inventario o facturación.

## 8. Alertas de servicio

F9.4 define señales operativas sin inventar umbrales comerciales que todavía no han sido medidos en producción.

| Señal | Condición | Clasificación | Acción |
|---|---|---|---|
| `SERVICE_TELEMETRY_DEGRADED` | aparece `OBSERVABILITY_PERSIST_FAILED` | warning operacional | revisar canal de telemetría; la operación de negocio no se revierte |
| `BATCH_PARTIAL_FAILURE` | un job termina con uno o más ítems fallidos | error operacional | triage del job usando `job_id`/`trace_id` y estado funcional persistido |
| `TENANT_ISOLATION_VIOLATION` | cualquier evidencia de métricas/logs cruzados entre tenants | incidente de seguridad / release blocker | detener liberación y corregir antes de continuar |
| `PII_SECRET_LOG_EXPOSURE` | aparece JWT, Authorization, email, DNI/RUC, secreto o payload sensible en logs | incidente de seguridad / release blocker | detener liberación, contener evidencia y corregir la fuga |

Además se monitorizan como señales de tendencia:

- tasa de `failed` por componente;
- p95/p99 de duración por tenant/componente;
- volumen de `denied` 401/403;
- frecuencia de jobs `skipped` y `BATCH_PARTIAL_FAILURE`.

Los 401/403 se contabilizan como `denied` y **no se consideran automáticamente caída del servicio**.

No se fija en esta fase un porcentaje de error ni un límite p95/p99 arbitrario. Los umbrales numéricos de alerta deben calibrarse con la línea base medida en T16/T19 y documentarse antes de producción; esa calibración no debe reinterpretarse como SLA contractual salvo decisión explícita posterior.

## 9. Cobertura Edge

El gate enumera dinámicamente los directorios inmediatos de `supabase/functions`, excluyendo `_shared`.

Para cada directorio con `index.ts` exige:

- importar la capa de observabilidad;
- ejecutar el handler mediante `serveObserved`;
- usar como componente el nombre estático de la Edge Function.

La implementación actual cubre los **21 entrypoints HTTP** inventariados. El número no se hardcodea como límite futuro: cualquier nueva función entra automáticamente en el análisis.

## 10. Contrato pgTAP

`observability_contract_test.sql` congela 22 assertions sobre:

- existencia de ledger;
- RLS;
- ausencia de CRUD directo authenticated;
- inexistencia de columnas libres/PII;
- índices tenant/trace/job;
- writer `service_role`-only mediante privilegios `EXECUTE`;
- writer `SECURITY DEFINER`;
- firma writer sin payload/PII;
- validación allowlisted;
- RPC de métricas;
- tenant/admin enforcement;
- p50/p95/p99;
- RPC de errores recientes sanitizada.

Estas assertions quedan pendientes de ejecución en Supabase local dentro de T04.

## 11. Validación dinámica requerida

F9.4 no se considera certificada dinámicamente hasta ejecutar el mapa maestro.

### T02

Ejecutar:

```bash
node scripts/verify_saas_observability.mjs --self-test
node scripts/verify_saas_observability.mjs
```

### T04

El pgTAP de base debe incluir:

```text
supabase/tests/database/observability_contract_test.sql
```

### T16

Con ORG_A y ORG_B reales del laboratorio:

1. ejecutar Edge de ambas empresas;
2. comprobar `x-stomni-trace-id` UUID en respuesta;
3. comprobar que ADMIN_A sólo ve métricas/errores de ORG_A;
4. comprobar simétricamente ADMIN_B;
5. enviar un `x-stomni-trace-id` válido controlado y verificar correlación sin cambio de tenant;
6. enviar trace inválido y verificar sustitución por UUID nuevo;
7. provocar 401/403 y comprobar outcome `denied` sin PII;
8. ejecutar un batch vacío y comprobar `job_id` + `skipped`;
9. provocar de forma controlada un fallo batch y comprobar `BATCH_PARTIAL_FAILURE`;
10. revisar logs locales y confirmar que no aparecen JWT, Authorization, email, DNI/RUC, URLs con secretos ni payloads crudos;
11. registrar una línea base local de tasa `failed` y p95/p99 para calibración de alertas, sin declararla SLA.

No se deben usar datos reales de clientes para esta prueba.

### T19

El informe final debe conservar:

- commit candidato;
- resultado T02/T04/T16;
- ejemplos de `trace_id` y `job_id` ficticios;
- p50/p95/p99 medidos localmente;
- conteos failed/denied;
- confirmación de aislamiento A/B;
- confirmación de revisión de PII/secrets;
- línea base y umbrales operativos de alerta aprobados antes de producción.

## 12. Resultado

F9.4 puede marcarse cerrada **a nivel de implementación** cuando migración, wrapper, cobertura Edge, jobs, pgTAP, gate, auditoría, checklist y mapa maestro estén alineados.

La validación runtime sigue pendiente hasta T02/T04/T16/T19. En particular, no se declara aquí que los percentiles, los logs locales o las RPC tenant-scoped ya hayan sido ejecutados.

El **GATE BLOQUE 9 VERDE** permanece abierto hasta completar F9.5/F9.6 y la validación final correspondiente.
