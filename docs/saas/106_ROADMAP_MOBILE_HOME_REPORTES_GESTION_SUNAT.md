# Roadmap móvil — Inicio, Balance, Inventario, Ventas a crédito, Reportes y Gestión SUNAT

## 1. Objetivo

Reorganizar la experiencia móvil de StOmni SaaS para que cada pantalla tenga una responsabilidad clara, se eliminen duplicaciones y la navegación entre resumen, operación diaria, análisis histórico y gestión tributaria sea coherente.

Este roadmap no pretende rehacer la lógica de negocio existente. La prioridad es reorganizar la experiencia móvil reutilizando contratos, permisos y servicios actuales, y ampliar backend únicamente donde sea necesario para obtener agregados históricos correctos y escalables.

## 2. Responsabilidad final de cada área

- **Inicio:** panorama del negocio, tendencias y alertas que requieren atención.
- **Balance:** operación financiera del día actual.
- **Inventario:** estado actual del catálogo y existencias.
- **Reportes:** análisis histórico por período.
- **Gestión SUNAT:** operación y resolución de documentos electrónicos.
- **Centro de trabajo:** acceso a módulos especializados, incluyendo Reportes y Gestión SUNAT.

### Reglas de producto y diseño

1. No duplicar en Inicio datos operativos que ya pertenecen a Balance.
2. No usar Reportes para ejecutar acciones tributarias.
3. No usar Gestión SUNAT como motor de estadísticas históricas.
4. No contabilizar Guías de Remisión Electrónica como ventas o facturación monetaria.
5. Evitar cards contenedoras con otras cards cuando una jerarquía plana sea suficiente.
6. Mantener compatibilidad con modo claro, oscuro y color principal configurable.
7. Mantener permisos, capacidades y aislamiento multi-tenant existentes.
8. Todo cambio se implementa primero en el repositorio privado fuente de verdad y se valida posteriormente mediante el espejo CI.

## 3. Estado actual verificado

### Balance

Balance está limitado explícitamente al día actual mediante `AppTime.startOfToday()` y `AppTime.endOfToday()`.

Actualmente muestra ingresos, egresos, balance/neto, descuentos y movimientos del día, además del acceso al detalle de venta, gasto o pago. El CTA `Ver detalle` abre actualmente `ReportesPage`.

Por tanto, Balance seguirá siendo una pantalla operativa diaria y no se convertirá en histórico.

### Reportes

Actualmente dispone de dos pestañas: **Financiero** e **Inventario**. Soporta períodos Diario, Semanal, Mensual, Anual y Personalizado. Reportes es la pantalla apropiada para análisis histórico.

### Documentos electrónicos

La pantalla actual es operativa. Permite listar Facturas, Boletas, Notas y Guías; filtrar y buscar; consultar estado SUNAT; reintentar envíos; abrir documentos; crear GRE; y gestionar bajas, anulaciones y procesos tributarios.

Esta funcionalidad no debe desaparecer dentro de Reportes. Se renombrará y enfocará como **Gestión SUNAT**.

# 4. Fase 1 — Reestructuración de Inicio

## 4.1 Eliminar duplicaciones

Retirar de Inicio:

- cantidad total de productos registrados;
- cards de Ventas de hoy;
- cards de Egresos de hoy;
- Flujo neto como métrica independiente;
- actividad reciente de ventas/egresos que duplique Balance;
- la card contenedora grande que agrupa otras cards cuando no agrega jerarquía útil.

Balance ya cubre la actividad financiera diaria.

## 4.2 Nueva sección Rendimiento

Crear una sección visual plana con selector principal:

- Ventas
- Egresos
- Facturación

Selector temporal:

- 7 días
- 30 días
- Mes
- Año

Se mostrará un único gráfico que cambia según la selección.

### Ventas

Mostrar tendencia histórica de ventas.

### Egresos

Recuperar el gráfico histórico de egresos que existía anteriormente.

### Facturación

Mostrar evolución de facturación electrónica, separando principalmente Boletas y Facturas. No incluir GRE dentro del importe facturado.

## 4.3 CTA de Inicio

El CTA recomendado será **Analizar período**.

Comportamiento:

- Ventas + período -> Reportes > Financiero > Ingresos + mismo período.
- Egresos + período -> Reportes > Financiero > Egresos + mismo período.
- Facturación + período -> Reportes > Facturación + mismo período.

## 4.4 Alertas

Renombrar `Estado actual y alertas` a **Alertas**.

Mostrar únicamente situaciones accionables, por ejemplo:

- productos con stock bajo;
- productos agotados;
- cuentas vencidas por cobrar;
- pagos próximos o vencidos;
- comprobantes SUNAT rechazados;
- documentos pendientes de envío.

Cada alerta deberá navegar al módulo que permite resolverla.

Si no existen alertas: **Todo en orden — No tienes alertas pendientes.**

## 4.5 Criterios de aceptación

- Inicio no duplica Ventas/Egresos/Neto de hoy.
- Inicio no muestra el total de productos registrados.
- Existe un único gráfico de Rendimiento.
- Ventas, Egresos y Facturación comparten la misma zona visual.
- El período seleccionado se conserva al navegar a Reportes.
- Alertas contiene únicamente elementos accionables.
- No existen cards decorativas anidadas innecesariamente.

# 5. Fase 2 — Ajuste menor de Balance

Balance conserva su responsabilidad actual: **qué ocurrió hoy con el dinero**.

## 5.1 Mantener

- ingresos de hoy;
- egresos de hoy;
- balance neto del día;
- descuentos;
- movimientos;
- acceso al detalle de cada operación;
- caja chica y sincronización actual.

## 5.2 Cambiar CTA

Cambiar el actual `Ver detalle` por **Histórico financiero**.

Debe abrir directamente `Reportes > Financiero`.

## 5.3 Criterios de aceptación

- Balance continúa limitado al día actual.
- No se agregan gráficos históricos a Balance.
- Histórico financiero abre Reportes > Financiero.
- No se duplica el selector de Rendimiento de Inicio.

# 6. Fase 3 — Ajuste menor de Inventario

Mover el contador de productos registrados desde Inicio hacia Inventario.

## 6.1 Resumen superior

Agregar un resumen compacto, sin una gran card contenedora:

- Productos
- Stock bajo
- Sin stock

Ejemplo conceptual: `428 productos · 17 stock bajo · 3 sin stock`.

## 6.2 Indicadores interactivos

- tocar Productos -> mostrar todos;
- tocar Stock bajo -> aplicar filtro de stock bajo;
- tocar Sin stock -> aplicar filtro de agotados.

## 6.3 Criterios de aceptación

- El total de productos ya no aparece en Inicio.
- Inventario muestra total de productos, stock bajo y agotados.
- Los indicadores aplican filtros reales.
- No se altera el flujo actual de creación, edición o consulta de productos.

# 7. Fase 4 — Reorganización de Reportes

Convertir Reportes en el centro de análisis histórico.

Nueva estructura: **Financiero | Inventario | Facturación**.

## 7.1 Filtros globales

Mantener Diario, Semanal, Mensual, Anual y Personalizado.

Reportes deberá poder recibir contexto inicial desde otras pantallas:

- pestaña;
- período;
- fecha/rango;
- tipo financiero;
- tipo de documento o estado cuando corresponda.

## 7.2 Reportes > Financiero

Mantener y mejorar:

- Ingresos;
- Egresos;
- Flujo neto;
- Descuentos;
- movimientos del período;
- distribución por método de pago;
- exportación.

### Flujo neto

Se mantiene únicamente como indicador histórico: `Ingresos - Egresos = Flujo neto`. No se presentará como utilidad o ganancia contable.

## 7.3 Reportes > Inventario

Mantener entradas, salidas, traslados, filtros por producto, histórico de movimientos y exportaciones actuales.

## 7.4 Criterios de aceptación

- Reportes tiene tres pestañas.
- Puede abrir en una pestaña, filtro y período específicos.
- Los filtros globales son consistentes entre las tres pestañas.
- El contexto recibido desde Inicio o Balance se respeta al abrir.

# 8. Fase 5 — Venta electrónica a crédito

La venta a crédito ya existe en StOmni para Ticket Interno, pero actualmente la UI y la política fiscal fuerzan el uso de `ticket_interno` cuando la venta es crédito.

El objetivo de esta fase es permitir también:

- Factura electrónica al contado;
- Factura electrónica a crédito;
- Boleta electrónica al contado;
- Boleta electrónica a crédito;
- Ticket interno al contado;
- Ticket interno a crédito.

La Nota de débito no formará parte del selector de comprobante de una venta nueva. Es un documento fiscal posterior que modifica un comprobante ya emitido.

## 8.1 Cambios en Procesar venta

Mantener las dos modalidades principales:

- Cobro completo
- Crédito / Deuda

En ambas modalidades permitir seleccionar:

- Ticket Interno
- Boleta Electrónica
- Factura Electrónica

Eliminar la lógica móvil que actualmente, al entrar a Crédito / Deuda, fuerza:

`_tipoComprobante = 'ticket_interno'`

La selección fiscal seguirá respetando capacidades por empresa y configuración SUNAT.

## 8.2 Condiciones de pago

Cuando la venta sea a crédito se deberá capturar:

- total de la venta;
- abono inicial opcional;
- monto pendiente;
- modalidad de vencimiento;
- fecha de vencimiento única o cronograma de cuotas;
- método del abono inicial cuando exista.

Ejemplo:

`Total S/ 1,000 · Abono S/ 200 · Pendiente S/ 800`

El pendiente puede manejarse como:

- pago único;
- dos o más cuotas.

La suma de cuotas deberá ser exactamente igual al monto pendiente, respetando tolerancia monetaria controlada server-side.

## 8.3 Modelo de cuotas

No limitar el SaaS a una sola fecha de vencimiento.

Crear un modelo tenant-aware equivalente a `venta_cuotas`, con al menos:

- organization_id;
- venta_id;
- número de cuota;
- monto original;
- fecha de vencimiento;
- monto pagado;
- estado;
- timestamps de auditoría.

El nombre final de tabla/contrato se definirá respetando las convenciones del esquema existente.

Los estados deberán permitir distinguir como mínimo:

- pendiente;
- parcialmente pagada;
- pagada;
- vencida;
- anulada/invalidada por ajuste cuando corresponda.

## 8.4 Política fiscal

Modificar `PeruSunatFiscalPolicy` para retirar el bloqueo artificial que hoy prohíbe Factura/Boleta a crédito.

La validación deberá continuar fail-closed y comprobar:

- documento fiscal válido;
- identidad exigida por tipo de comprobante;
- fechas válidas;
- total > 0;
- abono no mayor al total;
- pendiente consistente;
- cuotas válidas;
- vencimientos válidos;
- capacidad de facturación electrónica habilitada para la empresa.

No relajar las restricciones de emisión electrónica offline.

## 8.5 Backend de venta

Los entrypoints actuales `process_sale_v4` y `process_sale_with_units_v4` ya reciben simultáneamente:

- `p_es_credito`;
- `p_monto_abono`;
- `p_tipo_comprobante`.

Se mantendrán como entrada de venta, ampliando el contrato únicamente donde sea necesario para persistir y validar el cronograma.

El servidor deberá validar atómicamente:

`total = abono inicial + saldo pendiente`

y, cuando existan cuotas:

`saldo pendiente = suma(cuotas)`

La creación de venta, pagos iniciales, deuda/cuotas, stock y comprobante deberá conservar idempotencia y consistencia transaccional.

## 8.6 Emisión SUNAT de crédito

El generador fiscal actual construye los comprobantes con forma de pago `Contado`.

Debe ampliarse para generar correctamente la modalidad:

- Contado;
- Crédito.

Para Crédito deberá incluir en el XML/contrato fiscal vigente:

- monto neto pendiente;
- vencimiento cuando corresponda;
- cuotas con monto y fecha cuando existan.

La implementación deberá validarse contra el catálogo y especificación SUNAT vigentes al momento de desarrollar esta fase.

## 8.7 Balance

Una venta a crédito no debe contabilizar el total facturado como ingreso de caja.

Ejemplo:

`Factura S/ 1,000 · Abono inicial S/ 200 · Pendiente S/ 800`

Balance registra hoy únicamente:

`Ingreso real: S/ 200`

Los S/ 800 restantes aparecerán en cuentas por cobrar y sólo entrarán a Balance cuando sean efectivamente pagados.

## 8.8 Deudas y cobros

Los cobros posteriores deberán:

- registrar `pagos_venta`;
- reducir el saldo exigible;
- aplicar el pago a las cuotas correspondientes;
- actualizar estados de cuota;
- detectar vencidas;
- conservar idempotencia.

Una venta completamente pagada podrá volver a tener saldo pendiente si posteriormente una Nota de débito aceptada incrementa el monto exigible.

## 8.9 Criterios de aceptación

- Crédito no fuerza Ticket Interno.
- Factura y Boleta pueden emitirse correctamente a crédito.
- El abono inicial se registra como ingreso real.
- El saldo no pagado no aparece como caja.
- Pago único y múltiples cuotas son soportados.
- Las cuotas son tenant-aware.
- El XML fiscal representa correctamente Contado/Crédito.
- El flujo conserva idempotencia y aislamiento por empresa.

# 9. Fase 6 — Nota de débito electrónica

La Nota de débito se implementará como un documento fiscal posterior asociado a una Factura o Boleta existente.

No será un nuevo tipo de venta ni aparecerá como opción al crear una venta.

## 9.1 Origen y elegibilidad

Desde el detalle de una venta con comprobante electrónico elegible se podrá acceder a:

- Ver comprobante;
- Emitir Nota de crédito;
- Emitir Nota de débito;
- Crear Guía de remisión.

La Nota de débito deberá vincularse al comprobante original y validar server-side:

- tenant actual;
- comprobante existente;
- comprobante perteneciente a la misma organización;
- tipo de comprobante compatible;
- estado tributario compatible;
- motivo fiscal permitido;
- importe válido;
- idempotencia.

Los motivos y códigos se tomarán del catálogo SUNAT vigente; no se asumirán valores permanentes únicamente desde UI.

## 9.2 Modelo fiscal

Crear un dominio tenant-aware para Nota de débito equivalente a:

- `notas_debito`;
- detalles fiscales si el motivo requiere desglose;
- `notas_debito_intentos`.

Cada registro deberá conservar:

- organization_id;
- comprobante origen;
- venta origen;
- serie;
- correlativo;
- motivo;
- descripción/sustento;
- total;
- estado;
- request_id/idempotencia;
- paths XML/PDF/CDR;
- auditoría de envío;
- baja tributaria cuando corresponda.

## 9.3 Series y correlativos

Añadir soporte de serie/correlativo de Nota de débito dentro del namespace del tenant.

No compartir correlativos globales entre empresas.

La serie deberá configurarse por organización igual que el resto de documentos fiscales.

## 9.4 RPC y seguridad

Crear entrypoints públicos mínimos y tenant-safe para:

- crear Nota de débito;
- consultar disponibilidad/origen cuando sea necesario;
- reintentar/consultar mediante los canales fiscales existentes.

Requisitos:

- autenticación;
- permiso fiscal;
- organization_id derivado server-side;
- no confiar en organization_id enviado por Flutter;
- SECURITY DEFINER endurecido cuando sea estrictamente necesario;
- revocación explícita de PUBLIC/anon;
- idempotencia;
- validación de origen dentro del mismo tenant.

## 9.5 Edge Functions y emisión

Añadir soporte para:

- construir XML UBL de Nota de débito;
- firmar;
- enviar;
- recibir/guardar CDR;
- generar PDF;
- consultar estado;
- reintentar;
- reconciliar resultados inciertos.

Reutilizar la infraestructura fiscal compartida cuando sea seguro, sin mezclar estados de NC y ND.

## 9.6 Core logic y móvil

Agregar:

- modelo/record de Nota de débito;
- repository/use case;
- métodos de FacturacionService;
- pantalla Emitir Nota de débito;
- pantalla Ver Nota de débito;
- estados, errores y reintentos;
- listado de ND relacionadas en Ver Venta.

El detalle de una venta deberá mostrar claramente NC y ND relacionadas sin alterar el total original almacenado de la venta.

## 9.7 Stock

Por defecto, una Nota de débito es un ajuste monetario/fiscal y no debe consumir ni reponer stock automáticamente.

Cualquier supuesto futuro que requiera efecto de inventario deberá tener un contrato explícito y pruebas propias; no reutilizar ciegamente la lógica de Nota de crédito.

## 9.8 Gestión SUNAT

Gestión SUNAT deberá incorporar:

- Notas de débito en el listado;
- filtro por Notas de débito;
- consulta;
- reintento;
- estados;
- acceso al documento;
- errores/rechazos.

El gateway de documentos electrónicos deberá distinguir al menos:

- factura;
- boleta;
- nota_credito;
- nota_debito;
- guia.

## 9.9 Criterios de aceptación

- ND sólo nace desde un comprobante compatible.
- ND tiene serie/correlativo por empresa.
- ND tiene idempotencia.
- ND puede emitirse, consultarse y reintentarse.
- ND no altera stock automáticamente.
- ND aparece en Gestión SUNAT y detalle de venta.
- Aislamiento ORG_A/ORG_B probado.

# 10. Fase 7 — Modelo canónico de monto exigible y deuda

Antes de construir estadísticas finales, unificar la forma en la que StOmni calcula cuánto debe realmente un cliente.

Actualmente partes del dominio calculan saldo desde `ventas.total - pagos_venta`. Ese cálculo no es suficiente una vez que existen NC y ND.

## 10.1 Fórmula canónica

Definir server-side:

`Monto exigible = Venta original - NC monetarias aceptadas + ND aceptadas`

y:

`Saldo pendiente = Monto exigible - pagos confirmados`

La definición exacta deberá excluir documentos:

- rechazados;
- pendientes;
- anulados/baja aceptada;
- que no afecten dinero.

## 10.2 Venta original inmutable

No aumentar ni disminuir `ventas.total` por NC/ND.

`ventas.total` debe seguir representando la operación original.

Los ajustes fiscales se mantienen separados y se reflejan mediante el cálculo canónico de monto exigible.

## 10.3 Integración con cuotas

Cuando cambie el monto exigible por una NC/ND aceptada:

- recalcular saldo pendiente;
- reconciliar cronograma de cuotas;
- no perder pagos ya aplicados;
- no generar saldo negativo;
- volver a abrir una deuda si una ND crea nuevo pendiente;
- ajustar o cerrar cuotas según reglas explícitas y auditables.

La política concreta de redistribución de ajustes sobre cuotas deberá quedar centralizada en backend y cubierta por pruebas.

## 10.4 Integración con pagos

El RPC de cobro no deberá validar únicamente contra `ventas.saldo` derivado del total original.

Deberá usar la fuente canónica de saldo exigible y mantener:

- bloqueo transaccional;
- idempotencia;
- validación de sobrepago;
- asignación a cuotas;
- actualización de estado de deuda.

## 10.5 Reportes y Balance

**Balance** representa efectivo:

- pagos efectivamente cobrados;
- egresos efectivamente realizados.

**Facturación** representa documentos fiscales emitidos/aceptados según la definición del reporte.

**Cuentas por cobrar** representa saldo exigible todavía no cobrado.

No mezclar estas tres magnitudes.

## 10.6 Criterios de aceptación

- NC aceptada reduce monto exigible.
- ND aceptada aumenta monto exigible.
- Un documento pendiente/rechazado no altera deuda.
- Los pagos reducen únicamente saldo pendiente.
- No se modifica el total original de la venta.
- Una venta pagada puede reabrirse como deuda tras ND aceptada.
- No existe sobrepago por carrera concurrente.

# 11. Fase 8 — Backend agregado para facturación

La lista operativa de documentos trabaja con paginación y no se usará para sumar estadísticas.

Crear un contrato agregado server-side por organización y período.

Debe devolver como mínimo:

- total bruto de Facturas;
- total bruto de Boletas;
- total de NC monetarias;
- total de ND;
- facturación neta;
- cantidad por tipo;
- cantidad por estado;
- serie temporal agregada;
- cantidad de GRE;
- desglose contado/crédito;
- pendiente por cobrar asociado al período cuando el concepto del reporte lo requiera.

## 11.1 Fórmula de facturación neta

Conceptualmente:

`Facturación neta = Facturas + Boletas - NC monetarias aceptadas + ND aceptadas`

La implementación deberá definir con precisión:

- fecha usada para cada documento;
- tratamiento de bajas;
- documentos pendientes/rechazados;
- moneda;
- redondeos;
- notas que no afectan dinero.

## 11.2 Requisitos

- tenant actual derivado del contexto autenticado;
- sin posibilidad de consultar otra organización;
- permisos/capabilities respetados;
- rangos validados;
- no exponer payload tributario sensible innecesario;
- respuesta adecuada para gráficos sin descargar miles de documentos;
- no usar resultados paginados de Gestión SUNAT como fuente de agregación.

## 11.3 Pruebas

Agregar pruebas de:

- aislamiento multi-tenant;
- períodos;
- estados;
- Facturas;
- Boletas;
- NC;
- ND;
- contado/crédito;
- GRE excluidas del total monetario;
- bajas/anulaciones;
- datasets vacíos.

# 12. Fase 9 — Nueva sección Reportes > Facturación

Esta sección será exclusivamente analítica.

## 12.1 KPIs por período

Mostrar:

- facturación neta;
- total por Facturas;
- total por Boletas;
- Notas de crédito;
- Notas de débito;
- cantidad total de documentos;
- aceptados;
- pendientes;
- rechazados;
- anulados/baja cuando aplique;
- cantidad de GRE emitidas;
- facturación al contado;
- facturación a crédito;
- cuentas por cobrar relacionadas sin confundirlas con caja.

## 12.2 Reglas monetarias

- Facturas y Boletas forman parte del importe fiscal.
- NC monetarias aceptadas reducen facturación neta.
- ND aceptadas incrementan facturación neta.
- GRE no suma importe de venta.
- una venta a crédito puede estar facturada sin haber sido cobrada;
- Balance no debe copiar el total facturado como ingreso.

## 12.3 Gráficos

Gráfico principal:

**Facturación por período**

Series principales:

- Boletas
- Facturas

Visualizaciones complementarias:

- NC vs ND;
- contado vs crédito;
- porcentaje Boletas vs Facturas;
- evolución temporal;
- documentos por estado.

## 12.4 Drill-down

Ejemplos:

- tocar `3 rechazados` -> Gestión SUNAT filtrada por rechazados y mismo período;
- tocar `58 Facturas` -> Gestión SUNAT filtrada por Facturas y mismo período;
- tocar `4 Notas de débito` -> Gestión SUNAT filtrada por ND;
- tocar `17 Guías` -> Gestión SUNAT filtrada por GRE y mismo período.

## 12.5 Criterios de aceptación

- Las estadísticas son completas para todo el período.
- NC y ND afectan correctamente facturación neta.
- Crédito no se confunde con efectivo cobrado.
- GRE no afecta el total facturado.
- Los estados tributarios son navegables hacia Gestión SUNAT.

# 13. Fase 10 — Renombrar Documentos electrónicos a Gestión SUNAT

En Centro de trabajo, **Documentos** pasa a **Gestión SUNAT**.

Subtítulo recomendado: `Comprobantes, envíos, consultas y bajas`.

La pantalla mantiene su función operativa.

## 13.1 Mantener y ampliar

- Facturas;
- Boletas;
- Notas de crédito;
- Notas de débito;
- Guías;
- búsqueda;
- filtros;
- consulta de estado SUNAT;
- reintento de envío;
- detalle del documento;
- creación de GRE;
- anulaciones/bajas;
- procesos tributarios.

## 13.2 No convertir en reporte

Gestión SUNAT no calculará facturación histórica, evolución por período ni KPIs agregados.

Eso pertenece a Reportes > Facturación.

# 14. Fase 11 — Mejorar UX de Gestión SUNAT

## 14.1 Filtros operativos

Prioridad por estado:

- Todos
- Pendientes
- Rechazados
- Aceptados

Tipo:

- Facturas
- Boletas
- Notas de crédito
- Notas de débito
- Guías

Mantener búsqueda por número, cliente y estado.

## 14.2 Jerarquía visual

Los documentos problemáticos deben destacar más que los aceptados. Un documento rechazado debe mostrar claramente el motivo y la acción de reintento; un documento aceptado puede mostrarse de forma más discreta.

## 14.3 Acceso a análisis

Agregar **Ver reporte de facturación**, que abre `Reportes > Facturación` con el período actual cuando aplique.

# 15. Fase 12 — Navegación cruzada

## Inicio -> Reportes

- Ventas -> Financiero / Ingresos
- Egresos -> Financiero / Egresos
- Facturación -> Facturación

## Balance -> Reportes

- Histórico financiero -> Financiero

## Reportes -> Gestión SUNAT

- Facturas -> Gestión SUNAT / Facturas
- Boletas -> Gestión SUNAT / Boletas
- Notas de crédito -> Gestión SUNAT / NC
- Notas de débito -> Gestión SUNAT / ND
- Rechazados -> Gestión SUNAT / Rechazados
- Pendientes -> Gestión SUNAT / Pendientes
- GRE -> Gestión SUNAT / Guías

## Gestión SUNAT -> Reportes

- Ver reporte de facturación -> Reportes / Facturación

## Venta -> Gestión fiscal

Desde Ver Venta:

- comprobante -> ver documento;
- NC -> emitir/ver Nota de crédito;
- ND -> emitir/ver Nota de débito;
- GRE -> crear/ver Guía.

Toda navegación debe preservar el período cuando sea semánticamente válido.

# 16. Fase 13 — Unificación visual móvil

Aplicar a:

- Inicio;
- Balance;
- Inventario;
- Procesar Venta;
- Ver Venta;
- Reportes;
- Gestión SUNAT;
- emisión/detalle de NC;
- emisión/detalle de ND.

Objetivos:

- eliminar gradientes decorativos de títulos;
- reducir cards anidadas;
- usar superficies planas;
- unificar tipografía;
- unificar radios y espaciado;
- respetar color principal configurable;
- soportar claro/oscuro;
- mantener colores semánticos únicamente cuando aporten significado;
- conservar formularios y lógica operativa.

No se realizará una refactorización visual de escritorio dentro de este bloque.

# 17. Fase 14 — Pruebas y gates

## Inicio

- no duplica Balance;
- Productos registrados no vuelve a Inicio;
- Alertas solo muestra elementos relevantes;
- Rendimiento conserva filtros y navegación.

## Balance

- sigue usando el día actual;
- sólo cuenta efectivo realmente cobrado;
- Histórico financiero abre Reportes correctamente.

## Inventario

- muestra total/stock bajo/sin stock;
- los contadores filtran correctamente.

## Venta a crédito

- Ticket/Boleta/Factura soportan crédito según capacidades;
- no se fuerza Ticket Interno;
- abono inicial correcto;
- pago único correcto;
- múltiples cuotas correctas;
- cronograma tenant-aware;
- XML de crédito correcto;
- idempotencia y concurrencia.

## Deudas

- saldo canónico correcto;
- NC reduce;
- ND aumenta;
- pagos reducen;
- sobrepago rechazado;
- cuotas vencidas identificadas;
- deuda puede reabrirse por ND.

## Nota de débito

- origen válido;
- correlativo por tenant;
- creación;
- emisión;
- consulta;
- reintento;
- CDR;
- resultado incierto;
- baja cuando corresponda;
- sin efecto de stock implícito.

## Reportes

- tres pestañas presentes;
- parámetros iniciales funcionan;
- períodos correctos;
- Flujo neto correcto;
- navegación a Gestión SUNAT correcta.

## Facturación

- totales completos;
- Facturas/Boletas correctas;
- NC/ND correctas;
- contado/crédito diferenciados;
- GRE excluidas del monto;
- estados tributarios correctos;
- aislamiento multi-tenant.

## Gestión SUNAT

- consultar;
- reintentar;
- ND incluida;
- crear GRE;
- procesos tributarios;
- filtros por estado/tipo;
- navegación hacia Reportes.

# 18. Orden de implementación recomendado

1. Mantener y validar el contrato de navegación hacia Reportes ya iniciado.
2. Ampliar modelo de venta para Crédito/Deuda con Factura y Boleta.
3. Diseñar/persistir cronograma de cuotas tenant-aware.
4. Ampliar RPC de venta y validaciones de pago/crédito.
5. Adaptar XML fiscal de Factura/Boleta para Contado/Crédito.
6. Unificar cálculo canónico de monto exigible y saldo.
7. Adaptar cobros/deudas/cuotas al saldo canónico.
8. Implementar dominio DB/RLS/RPC de Nota de débito.
9. Implementar emisión/reintento/consulta SUNAT de Nota de débito.
10. Integrar ND en core logic, Ver Venta y Gestión SUNAT.
11. Crear backend agregado de facturación con Factura/Boleta/NC/ND/GRE y contado/crédito.
12. Reestructurar Reportes y añadir Reportes > Facturación.
13. Renombrar Documentos -> Gestión SUNAT y cerrar sus filtros operativos.
14. Reestructurar Inicio usando los contratos fiscales ya completos.
15. Ajustar CTA de Balance.
16. Mover indicadores de productos a Inventario.
17. Conectar alertas de Inicio, incluyendo cuotas vencidas y documentos SUNAT problemáticos.
18. Ejecutar pasada visual conjunta sobre las superficies móviles afectadas.
19. Ejecutar pruebas, formato, análisis y gates.
20. Sincronizar mirror CI.
21. Requerir validación completa 7/7.
22. Generar nueva build QA sólo después de CI verde.

Este orden evita construir Inicio y Reportes sobre un modelo fiscal incompleto y evita rehacerlos inmediatamente después al introducir Crédito o Nota de débito.

# 19. Fuera de alcance

- rediseño completo de escritorio;
- cambios generales de core business no relacionados;
- cambios de precios/suscripciones;
- despliegue a producción;
- eliminación de Gestión SUNAT;
- uso de GRE como ingreso financiero;
- contabilizar una Factura/Boleta a crédito como efectivo antes del cobro;
- tratar Nota de débito como una venta nueva;
- modificar stock automáticamente por una ND sin contrato explícito.

# 20. Definición de terminado

El bloque se considera cerrado únicamente cuando:

- Inicio, Balance, Inventario, Ventas, Reportes y Gestión SUNAT cumplen las responsabilidades definidas;
- Factura y Boleta pueden operar al contado o a crédito correctamente;
- el cronograma de cuotas funciona por tenant;
- Balance refleja sólo dinero efectivamente cobrado;
- el monto exigible usa Venta original - NC aceptadas + ND aceptadas;
- los pagos reducen correctamente el saldo y las cuotas;
- Nota de débito dispone de DB, seguridad, emisión, CDR, consulta, reintento y UI;
- no existen duplicaciones relevantes entre Inicio y Balance;
- Reportes centraliza el histórico;
- Gestión SUNAT conserva las acciones operativas;
- Facturación dispone de agregados server-side completos y tenant-safe;
- GRE queda fuera del monto facturado;
- la experiencia claro/oscuro es consistente;
- pruebas nuevas y existentes pasan;
- el mirror corresponde al source privado;
- CI público termina 7/7 verde;
- la build QA posterior se genera desde el SHA privado validado.

