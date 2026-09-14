# Fase 6.3 — Dashboard configurable

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908052000_saas_configurable_dashboard_tenant.sql`
- `supabase/migrations/20260908052100_saas_configurable_dashboard_audit.sql`

Gate:

- `scripts/verify_saas_configurable_dashboard.mjs`

pgTAP:

- `supabase/tests/database/configurable_dashboard_contract_test.sql` — 30 assertions.

## Corrección SaaS descubierta

La implementación histórica de métricas configurables seguía siendo singleton:

- `business_metric_definitions.business_id`;
- seed con `business_id = 1`;
- `list_business_metrics_v1()` filtraba `business_id=1`;
- `save_business_metrics_v1()` eliminaba y recreaba definiciones de `business_id=1`.

En un sistema multiempresa esto habría compartido configuración de KPIs entre organizaciones. F6.3 elimina esa dependencia por completo.

`business_metric_definitions` pasa a:

```text
PRIMARY KEY (organization_id, source_key)
UNIQUE      (organization_id, position)
```

`business_id` se elimina del contrato final y cada organización nueva recibe su catálogo de métricas por trigger.

## Cálculo autoritativo

Flutter deja de descargar reportes crudos para calcular KPIs configurables localmente.

El cálculo final vive en:

`get_configurable_dashboard_v1(p_start, p_end, p_branch_id)`

El RPC:

- deriva `organization_id` server-side;
- exige `reports.view_profit`;
- limita el periodo a 366 días;
- valida que una sucursal opcional pertenezca al tenant actual;
- devuelve únicamente métricas habilitadas para esa organización;
- incorpora `available` y `note` para evitar inventar cifras cuando el modelo todavía no permite un cálculo fiable.

## Fuentes disponibles

El catálogo final incluye:

- ingresos cobrados;
- gastos pagados;
- flujo neto;
- descuentos;
- cantidad de ventas;
- entradas de inventario;
- salidas de inventario;
- ventas;
- margen bruto;
- rotación de inventario;
- inventario inmovilizado;
- cuentas por cobrar;
- rendimiento de caja.

## Periodo y sucursal

### Organización completa

Sin `p_branch_id`, todas las consultas se filtran exclusivamente por el `organization_id` resuelto para la sesión.

### Sucursal

El esquema actual no posee todavía un `ventas.branch_id` autoritativo. F6.3 no infiere una sucursal de forma arbitraria.

Se aplican estas reglas:

- inventario: `almacenes.branch_id`;
- movimientos financieros: sólo movimientos con `cash_register_id` atribuible a una caja de la sucursal;
- ventas: una venta pertenece a la sucursal sólo cuando sus líneas de almacén son inequívocamente de esa sucursal;
- una venta con líneas de varias sucursales no se duplica ni se adjudica artificialmente a una sola.

El RPC devuelve `scope_note` para que la UI pueda explicar esta semántica.

## KPIs fail-closed

### Margen bruto

No existe todavía un costo histórico inmutable por línea de venta suficientemente autoritativo para calcular COGS histórico.

F6.3 **no usa `productos.precio_compra` actual como si fuera costo histórico**. Si `gross_margin` se habilita, devuelve:

- `available=false`;
- `value=null`;
- explicación del motivo.

### Rotación de inventario

Por la misma razón, `inventory_turnover` permanece no disponible hasta disponer de COGS histórico y una valoración promedio fiable.

Esta decisión evita mostrar indicadores financieros aparentemente exactos pero contablemente falsos.

## Inventario inmovilizado

V1 no suma cantidades de unidades incompatibles. Reporta el número de SKUs que:

- tienen stock actual positivo;
- son inventariables;
- no registraron salidas durante el periodo seleccionado.

## Cuentas por cobrar

`accounts_receivable` representa el saldo pendiente actual de ventas del tenant. Se documenta que este saldo es una foto actual y no se limita a ventas creadas dentro del periodo.

## Core Logic

`MetricSource` se amplía con los KPIs nuevos.

`MetricValue` pasa a soportar:

- `double? value`;
- `available`;
- `note`.

Se crea `ConfigurableDashboardSnapshot` y `ConfigurableMetricGateway.loadDashboard()`.

`ConfigurableMetricsUseCase` ya no depende de `ReportingGateway` para recalcular métricas en cliente. La función `evaluate()` se conserva como compatibilidad y devuelve las métricas calculadas por el backend.

## UI

### Mobile

`MetricasConfigurablesPage`:

- usa el contrato server-side;
- permite seleccionar 7/30/90/365 días;
- presenta métricas no disponibles de forma explícita;
- sigue permitiendo habilitar/deshabilitar y renombrar KPIs.

### Desktop

Se actualizaron dos superficies:

- `DesktopMetricsPanel`;
- `DesktopDashboardPanel`.

El dashboard principal muestra KPIs configurables de los últimos 30 días cuando el usuario posee autorización de reportes. La pantalla dedicada permite cambiar periodo y configuración.

## Auditoría

Los cambios de `business_metric_definitions` escriben en el ledger F6.1 mediante:

`business_metric_definitions_audit_change`

La metadata conserva únicamente etiqueta, posición, estado y formato de la métrica.

## Seguridad

- cero `business_id=1` en el contrato final F6.3;
- tenant derivado server-side;
- configuración por `organization_id`;
- sin INSERT/UPDATE/DELETE directo para `authenticated`;
- branch validado contra el tenant;
- RPC literal clasificado en el gate global;
- cambios de configuración auditados.

## Validación dinámica pendiente

T07/T09/T12/T13/T14 deberán demostrar, entre otros:

- definiciones A y B son independientes;
- guardar métricas A no elimina ni reordena métricas B;
- `get_configurable_dashboard_v1` A nunca incluye datos B;
- branch B es rechazado desde A;
- una venta multi-sucursal no se duplica en una sucursal;
- el mismo periodo produce resultados distintos cuando A/B tienen datos distintos;
- margen/rotación permanecen `available=false` mientras no exista costo histórico;
- mobile y desktop decodifican correctamente métricas disponibles/no disponibles;
- cambios de configuración generan audit log sólo en el tenant correspondiente.

## Resultado

F6.3 queda cerrada a nivel de implementación. El dashboard configurable deja de usar una configuración singleton y pasa a un cálculo autoritativo tenant-aware, con periodo, soporte seguro de sucursal y semántica fail-closed para indicadores que todavía no pueden calcularse con rigor histórico.
