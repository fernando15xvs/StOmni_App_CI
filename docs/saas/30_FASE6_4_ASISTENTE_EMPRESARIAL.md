# Fase 6.4 — Asistente empresarial StOmni

## Estado

**IMPLEMENTADA EN CÓDIGO COMO CAPA SEGURA DE CONTEXTO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908053000_saas_business_assistant_safe_context.sql`
- `supabase/migrations/20260908053100_saas_business_assistant_audit.sql`

Gate:

- `scripts/verify_saas_business_assistant.mjs`

pgTAP:

- `supabase/tests/database/business_assistant_contract_test.sql` — 28 assertions.

Core Logic:

- `assistant/domain/business_assistant.dart`
- `assistant/application/business_assistant_gateway.dart`
- `assistant/application/business_assistant_use_case.dart`
- `assistant/data/supabase_business_assistant_gateway.dart`
- `assistant/providers/business_assistant_providers.dart`

Gate maestro del Bloque 6:

- `scripts/verify_saas_intelligence_block.mjs`

## Alcance deliberado

F6.4 no conecta todavía StOmni con un proveedor externo de modelos de IA. Primero congela la frontera de datos que cualquier asistente futuro podrá consumir.

Esto evita diseñar una integración en la que un modelo reciba acceso directo a PostgreSQL, `service_role`, SQL libre o datos de todas las organizaciones.

La arquitectura final de V1 es:

```text
UI / futuro proveedor IA
        |
BusinessAssistantUseCase
        |
BusinessAssistantGateway
        |
get_business_assistant_context_v1(intent, periodo, branch, limit)
        |
PostgreSQL tenant-aware + permisos
```

El proveedor de IA, cuando se incorpore, sólo podrá recibir el resultado ya autorizado y agregado del RPC.

## Opt-in por empresa

Se crea `business_assistant_settings`, una fila por organización:

- `enabled=false` por defecto;
- máximo de resultados entre 1 y 50;
- periodo por defecto entre 1 y 365 días;
- `revision` para optimistic concurrency.

Por defecto una organización nueva **no puede usar el asistente** hasta que su administrador lo habilite explícitamente.

## Intenciones permitidas

`get_business_assistant_context_v1()` acepta únicamente:

- `replenishment`;
- `non_moving_products`;
- `overdue_receivables`;
- `margin_diagnostics`.

No existe parámetro para:

- SQL;
- nombre de tabla;
- schema;
- `organization_id`;
- funciones dinámicas;
- credenciales;
- service-role.

Una intención desconocida falla con error de validación.

## Reposición

Devuelve productos inventariables cuyo stock actual está en o por debajo del mínimo configurado.

El contexto puede incluir:

- producto;
- stock actual;
- stock mínimo;
- brecha hasta el mínimo;
- proveedor relacionado.

La respuesta indica expresamente que son sugerencias y **no genera órdenes de compra automáticamente**.

## Productos sin rotación

Devuelve SKUs con stock positivo y sin salidas durante el periodo solicitado.

El filtro respeta:

- `organization_id`;
- sucursal opcional mediante almacenes;
- límite máximo configurado por tenant.

## Cuentas por cobrar antiguas

Devuelve ventas pendientes con saldo positivo cuya antigüedad supera el periodo indicado.

Cuando existe filtro de sucursal se reutiliza la semántica segura F6.3: sólo se incluye una venta si pertenece inequívocamente a esa sucursal.

El contrato deja claro que el modelo actual utiliza antigüedad del saldo, porque todavía no existe una fecha contractual universal de vencimiento.

## Diagnóstico de margen

F6.4 conserva el fail-closed de F6.3.

Mientras no exista costo histórico inmutable por línea de venta:

- no se calcula margen con `productos.precio_compra` actual;
- no se inventa una causa de caída de margen;
- el contexto devuelve una explicación de indisponibilidad.

## Seguridad

El RPC:

1. deriva tenant mediante `private.require_current_organization_id()`;
2. exige `reports.view_profit`;
3. exige que el asistente esté habilitado en el tenant;
4. valida intención, periodo y límite;
5. valida `branch_id` contra la organización actual;
6. consulta exclusivamente tablas filtradas por `v_org`;
7. devuelve un payload estructurado y acotado.

No se usa `service_role` ni SQL dinámico.

## Core Logic

`BusinessAssistantIntent` es un enum cerrado. El cliente no construye nombres RPC o queries dinámicas.

`BusinessAssistantUseCase`:

- exige permisos mediante `OperationAuthorizer`;
- valida periodo/límite también en cliente;
- comprueba que la sesión no cambie durante la operación;
- administra settings únicamente mediante el gateway tipado.

El adaptador Supabase usa exclusivamente tres RPC literales:

- `get_business_assistant_settings_v1`;
- `update_business_assistant_settings_v1`;
- `get_business_assistant_context_v1`.

Todos están clasificados por el gate global RPC.

## Auditoría

Cada cambio de settings genera:

`assistant.settings.updated`

en `audit_logs`, incluyendo sólo:

- enabled;
- máximo de resultados;
- periodo por defecto;
- revision.

## Qué NO hace F6.4

F6.4 no:

- envía datos a OpenAI u otro proveedor;
- guarda prompts libres como instrucciones ejecutables;
- permite generación de SQL;
- concede acceso global a todos los tenants;
- ejecuta acciones de negocio automáticamente;
- modifica stock, compras, ventas o clientes a partir de una respuesta del asistente.

Estas restricciones son parte del contrato de seguridad, no limitaciones accidentales.

## Validación dinámica pendiente

T07/T09/T12/T13/T14 deberán demostrar, entre otros:

- asistente deshabilitado rechaza consultas;
- admin A puede habilitar A sin cambiar B;
- usuario A no puede enviar branch B;
- reposición A nunca incluye producto B;
- no-rotación A nunca consulta movimientos B;
- deudas A no incluyen ventas B;
- límite solicitado no puede superar el máximo del tenant;
- intención no allowlisted falla;
- margen no usa costo actual como histórico;
- settings con revision obsoleta fallan;
- cambio de settings genera audit log en A y no en B;
- core no envía `organization_id`, SQL, tabla o schema al RPC.

## Resultado

F6.4 queda cerrada a nivel de implementación como **frontera segura de contexto empresarial**. StOmni ya dispone de una interfaz lista para que, en una etapa posterior, un proveedor de IA transforme esos datos autorizados en lenguaje natural sin recibir acceso directo a la base ni saltarse RLS.

Con F6.1–F6.4 implementadas, el Bloque 6 queda completo a nivel de código. Su gate dinámico permanece pendiente hasta ejecutar T00–T19.
