# Fase 9.2 — Carga y concurrencia

## Estado

**IMPLEMENTADA COMO INFRAESTRUCTURA DE PRUEBA / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

F9.2 prepara y endurece las superficies necesarias para medir carga y concurrencia multiempresa sin declarar rendimiento comercial por inferencia.

La fase incorpora:

- migración aditiva: `supabase/migrations/20260908059200_saas_inventory_request_scope_hardening.sql`;
- contrato pgTAP: `supabase/tests/database/load_concurrency_contract_test.sql`;
- probe local: `supabase/tests/performance/multi_tenant_concurrency_probe.mjs`;
- gate estático: `scripts/verify_saas_load_concurrency.mjs`.

No se ejecutó GitHub Actions, no se aplicó DDL al Supabase remoto y no se cerró T17/T18.

## Hallazgo corregido antes de medir carga

La migración F3.4 había dejado deliberadamente algunos `request_id` de inventario con namespace global durante el rollout. Además, `private.assert_inventory_request_scope(uuid)` rechazaba un UUID si ese mismo valor ya existía en otra organización.

Ese comportamiento era seguro contra mezcla de datos, pero no era un contrato SaaS correcto: dos empresas independientes deben poder generar casualmente el mismo UUID sin reservarse mutuamente el namespace de idempotencia.

F9.2 termina esa transición.

## Idempotencia tenant-local de inventario

La autoridad final de idempotencia pasa a ser el tenant más el request:

```text
(organization_id, request_id)
```

La migración convierte las restricciones request-only de las tablas directas relevantes:

- `inventario_operaciones_idempotentes`;
- `sys_processed_requests`;
- `transferencias_stock`.

El bloque de migración inspecciona las constraints existentes y falla cerrado si encuentra un estado ambiguo o dependencias incompatibles. No se edita una migración histórica ya versionada.

`private.assert_inventory_request_scope(uuid)` conserva dos responsabilidades:

1. exigir una organización activa derivada server-side;
2. exigir `request_id` no nulo.

Ya no consulta filas de otras empresas para decidir si el UUID está disponible.

## Compatibilidad de recepción trazable

La implementación histórica de `register_traceable_merchandise_receipt_v1` usa internamente `request_id` como PK global y busca retries por ese UUID.

En lugar de reescribir de forma invasiva una rutina madura, F9.2 añade:

```text
private.inventory_tenant_request_key_v1(organization_id, request_id)
```

Para requests nuevos, el wrapper transforma el UUID externo en una clave interna determinista namespaced por tenant antes de delegar al motor legacy.

Para una recepción histórica del tenant actual que ya exista con el UUID literal anterior a F9.2, el wrapper conserva ese UUID literal. Así los retries legacy siguen siendo idempotentes.

El helper permanece privado y no tiene `EXECUTE` para `anon` ni `authenticated`.

## Contención de inventario

El contrato congela las primitivas de exclusión ya existentes en los caminos críticos:

- ingreso de mercadería: advisory lock por `organization_id + request_id`;
- merma: advisory lock transaccional;
- traslado: advisory lock transaccional;
- alta producto+stock: advisory lock por tenant/request;
- consumo por lote: selección `FOR UPDATE` antes de descontar.

El objetivo no es serializar empresas distintas entre sí. El lock de idempotencia incorpora el tenant, por lo que ORG_A y ORG_B pueden operar con el mismo UUID sin bloquearse como si fueran una sola empresa.

## Índices tenant-leading

El pgTAP F9.2 comprueba al menos un índice cuyo primer componente sea `organization_id` en las tablas críticas de carga:

- clientes;
- productos;
- almacenes;
- saldos y movimientos de inventario;
- ventas;
- órdenes y recepciones de compra;
- gastos.

También exige caminos `(organization_id, request_id)` para:

- idempotencia general de inventario;
- alta producto+stock;
- transferencias;
- recepción/consumo trazable;
- compras como referencia de namespace correctamente migrado.

Esto no sustituye `EXPLAIN (ANALYZE, BUFFERS)` de T17: sólo impide perder estructuralmente los índices que deben poder utilizar esos planes.

## Correlativos concurrentes

El roadmap exige verificar correlativos además de inventario.

`correlativos_procesos_tributarios` ya tiene como PK:

```text
(organization_id, tipo_proceso, fecha_referencia)
```

`tributario_preparar_procesos` conserva:

- contexto `service_role` tenant-scoped derivado del header interno validado;
- `pg_advisory_xact_lock` sobre `organization_id + tipo_proceso + fecha`;
- `ON CONFLICT (organization_id, tipo_proceso, fecha_referencia)` para incrementar el contador;
- `FOR UPDATE SKIP LOCKED` al reclamar solicitudes pendientes.

De este modo dos workers de la misma organización no deben emitir el mismo correlativo, mientras ORG_A y ORG_B mantienen secuencias independientes.

Para comprobantes de venta, la rama fiscal de `process_sale_v3` selecciona la fila de `series_comprobantes` del tenant actual con `FOR UPDATE` y actualiza `ultimo_correlativo` con filtro `organization_id`.

El pgTAP congela estas propiedades. La prueba simultánea real de correlativos sigue pendiente de T17; no se considera demostrada sólo por inspección estática.

## Probe local de carga

`multi_tenant_concurrency_probe.mjs` sólo acepta Supabase local por HTTP loopback.

No acepta un proyecto `*.supabase.co`, HTTPS externo ni un host no loopback.

`service_role` se usa únicamente para aprovisionar identidades Auth sintéticas. Después:

- alta de empresa;
- onboarding;
- Data API;
- RPC de catálogo/inventario;
- lecturas y escrituras de carga

se realizan con `anon key + JWT authenticated`.

Por tanto, el probe ejerce RLS y autorización reales.

## Carga acotada y reproducible

Valores por defecto:

```text
STOMNI_LOAD_CUSTOMERS_PER_TENANT=40
STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT=20
STOMNI_LOAD_READS_PER_TENANT=40
STOMNI_LOAD_CONCURRENCY=8
```

Límites de seguridad del runner:

- clientes por tenant: máximo 2000;
- escrituras de inventario por tenant: máximo 1000;
- lecturas por tenant: máximo 2000;
- concurrencia: máximo 64.

El runner no es una herramienta de estrés ilimitado ni está diseñado para producción.

## Escenarios dinámicos automatizados

Cuando se ejecute en T17, el probe deberá demostrar:

1. ORG_A y ORG_B reales creadas y autenticadas;
2. mismo `request_id` para `crear_producto_con_stock` en A y B;
3. retry dentro de cada tenant devuelve el mismo producto;
4. burst concurrente de clientes A/B sin fuga cross-tenant;
5. lecturas concurrentes sólo devuelven el tenant autenticado;
6. dos ingresos simultáneos con el mismo request dentro de un tenant incrementan stock exactamente una vez;
7. el mismo request simultáneo en A y B incrementa cada tenant exactamente una vez;
8. múltiples ingresos concurrentes únicos dejan un delta de stock igual al número de operaciones exitosas.

## Evidencia de latencia

El probe calcula y persiste, por familia de operación:

- mínimo;
- media;
- p50;
- p95;
- p99;
- máximo.

La evidencia por defecto se guarda en:

```text
.dart_tool/saas/f9_2_load_report.json
```

El reporte lleva explícitamente:

```text
dynamic_certification = T17_PENDING_REVIEW
```

F9.2 queda **sin SLO comercial** inventado. Un umbral de GO sólo puede fijarse después de ejecutar T17 sobre hardware declarado, registrar baseline y decidir qué plataformas/volumen constituyen el objetivo comercial.

## Correlativos: validación dinámica pendiente

T17 deberá añadir evidencia real de al menos estos casos fiscales sobre fixtures sintéticos locales:

- dos preparaciones simultáneas del mismo tenant/tipo/fecha no generan correlativos duplicados;
- el reparto `FOR UPDATE SKIP LOCKED` no asigna la misma solicitud a dos procesos;
- ORG_A y ORG_B pueden usar el mismo tipo/fecha y mantener correlativos independientes;
- dos ventas fiscales concurrentes de un mismo tenant/serie no reciben el mismo correlativo;
- las series de ORG_A y ORG_B no se bloquean ni incrementan entre sí.

Estas pruebas deben usar únicamente datos fiscales ficticios y Supabase local.

## Gate anti-degradación

`scripts/verify_saas_load_concurrency.mjs` comprueba estáticamente:

- eliminación del precheck global de UUID en inventario;
- constraints tenant-local;
- namespace compatible de recepción trazable;
- 19 assertions pgTAP de locks, índices, idempotencia y correlativos;
- restricciones local-only del probe;
- límites máximos de carga;
- separación service-role/Auth normal;
- escenarios de contención exactly-once;
- mismo request en A/B;
- generación p50/p95/p99;
- integración de F9.2 en T02/T04/T17;
- Gate Bloque 9 aún abierto.

El `--self-test` introduce variantes inseguras para comprobar que el gate detecta pérdida de la guarda local, uso de `service_role` en operaciones de negocio, falsa certificación antes de T17 y eliminación de percentiles.

## Integración final

T02 ejecutará el gate F9.2 y su self-test.

T04 ejecutará el contrato pgTAP junto con los demás contratos de esquema.

T17 ejecutará el probe local, revisará el JSON de percentiles y realizará los escenarios fiscales concurrentes. También seguirá incluyendo `EXPLAIN (ANALYZE, BUFFERS)` para queries críticas.

T18 repetirá la suite después de un segundo `supabase db reset` limpio.

## Resultado

F9.2 queda cerrada **a nivel de implementación** cuando migración, pgTAP, probe, gate, checklist y mapa maestro estén versionados coherentemente.

Eso no equivale a afirmar que StOmni soporta una cantidad comercial concreta de usuarios, TPS o empresas. La **VALIDACIÓN DINÁMICA LOCAL PENDIENTE** permanece en T17/T18, y el Gate Bloque 9 no puede marcarse hasta cerrar F9.3–F9.6 y completar las pruebas finales.
