# Roadmap móvil — Inicio, Balance, Inventario, Ventas a crédito, Reportes y Gestión SUNAT

## 1. Objetivo

Reorganizar la experiencia móvil de StOmni SaaS para que cada pantalla tenga una responsabilidad clara, se eliminen duplicaciones y la navegación entre resumen, operación diaria, análisis histórico y gestión tributaria sea coherente.

El alcance combina una reorganización móvil con una ampliación del dominio financiero y fiscal: cuotas persistentes, saldo exigible, venta electrónica a crédito, notas de débito y agregados históricos. Se reutilizarán contratos, permisos y servicios existentes, pero estas ampliaciones requieren cambios de backend, migraciones compatibles y pruebas transaccionales. Cada fase constituye una entrega verificable; no debe confundirse una base de contratos con una funcionalidad terminada.

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

## 3. Línea base y seguimiento

Estado contrastado con el código fuente `519a89d31899e513d57a1826d93c691ed63aafc0`. Fechas expresadas en America/Lima. El documento se creó el 1 de noviembre de 2026 a las 22:17 y se amplió a las 22:40; esta reorganización es del 2 de noviembre de 2026.

| Entrega observada | Estado y límite |
|---|---|
| Contexto inicial de Reportes | Implementado: pestaña, período, fechas y filtro financiero. Solo existen Financiero e Inventario. |
| CTA de Balance | Implementado: Histórico financiero abre Financiero. Mantener el alcance diario y verificarlo al integrar crédito. |
| Dominio de cuotas | Implementados SaleCreditInstallment y SaleCreditTerms con validaciones; no equivale a cuotas persistidas. |
| Propagación de crédito | creditTerms llega hasta VentaProcessingRequest. El adaptador real todavía no lo envía a processSaleRpc. |
| Cola offline | Esquema 3 con credit_terms, compatibilidad con versiones previas y rechazo de versiones futuras. No habilita emisión electrónica offline. |
| Crédito electrónico | Pendiente: venta_page fuerza ticket_interno, PeruSunatFiscalPolicy bloquea crédito electrónico y el generador fiscal usa Contado. |
| ND y saldo canónico | Pendientes dentro de este roadmap; no considerar completa una fase por existir NC o deudas previas. |
| Inicio y Reportes de facturación | Pendientes: Inicio conserva métricas diarias/productos y Reportes solo tiene dos pestañas. |
| CI de la línea base | [Run 41386320071](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41386320071), 7/7 correcto; mirror 48de8ff referencia el source 519a89d. Valida lo existente, no todos los requisitos futuros. |
| QA | La ejecución de instaladores observada es anterior a los cambios de cuotas; no acredita una build con ellos. |

La numeración de las fases siguientes es el orden de implementación. Las pruebas se ejecutan en cada entrega; la última fase integra la regresión completa. El detalle existente se conserva, pero su estado inicial es pendiente salvo lo señalado expresamente.

Para cerrar una fase registrar: SHA fuente, cambios y migraciones, pruebas ejecutadas y resultados, run del espejo y limitaciones pendientes. Una funcionalidad solo se marca completa cuando cumple sus criterios de aceptación, no por tener modelos o tests aislados.

# 4. Fase 0 — Cerrar contratos y decisiones de negocio

**Estado:** contrato financiero definido en [107_CONTRATO_FINANCIERO_CREDITO_CUOTAS_AJUSTES.md](107_CONTRATO_FINANCIERO_CREDITO_CUOTAS_AJUSTES.md), con reglas y 28 casos de aceptación. Implementación pendiente; validación normativa SUNAT pendiente como gate de fases 3 y 4. **Dependencia:** línea base identificada. **Salida financiera:** decisiones documentadas antes de fijar esquema y RPC.

## 4.1 Decisiones definidas en el contrato 107

- Definir Ventas (operaciones realizadas), Cobros/Ingresos (dinero recibido), Facturación (documentos fiscales) y Cuentas por cobrar. No asumir que Ventas equivale a Ingresos.
- Fijar fecha de imputación por métrica/documento, zona horaria, límites de rango, monedas y redondeos. Distinguir saldo actual de ventas de un período de saldo histórico al cierre; este último requiere datos que permitan reconstruirlo.
- Definir asignación de pagos a cuotas, orden de vencimientos, pagos parciales/anticipados, reversos y redistribución de NC/ND. Determinar si vencida es un estado o una condición calculada compatible con pago parcial.
- Definir el tratamiento de un excedente tras NC sobre una venta ya cobrada: saldo a favor, devolución o política equivalente con auditoría. No borrar el excedente limitando el saldo a cero.
- Definir cómo se representan devoluciones y reversos de cobros, y cuándo afectan caja y saldo. Un ajuste fiscal por sí solo no representa una salida de efectivo.
- Especificar precisión monetaria del servidor y tolerancia única compartida con los clientes. Revisar el uso actual de double y tolerancia 0.01 antes de persistir; cubrir límites y acumulación de redondeos.
- Definir compatibilidad con ventas/deudas existentes sin cronograma y clientes antiguos. Establecer migración, reconciliación y estrategia de reversión sin perder pagos.
- Verificar especificaciones y catálogos SUNAT vigentes al implementar crédito/ND, dejando fuente y fecha de consulta. Este documento no certifica cumplimiento normativo.

## 4.2 Casos mínimos para cerrar las decisiones

- Venta 1,000; abono 200; cuotas que suman 800; cobro parcial y repetición idempotente.
- Venta 1,000 totalmente cobrada; NC monetaria aceptada de 200: deuda cero y excedente de 200 conservado hasta su resolución.
- Venta pagada; ND aceptada de 100: reapertura por 100, sin modificar total original ni stock.
- NC/ND pendiente o rechazada, aceptación repetida y baja posterior: efecto financiero definido y aplicado una sola vez.
- Dos cobros concurrentes sobre el mismo saldo, pago simultáneo con ajuste y reverso posterior.
- Cierres de período, rangos vacíos, múltiples monedas si están soportadas y comparación entre empresas.

**Criterio de salida financiero:** reglas y resultados esperados definidos en el contrato 107. Para dar por verificados los requisitos fiscales todavía se requieren fuentes oficiales y pruebas de las fases 3–4. No marcar la fase completa como validada mientras falte esa evidencia.

# 5. Fase 1 — Consolidar navegación de Reportes y Balance

**Estado:** base implementada; revisión estática contrastada en [diseño 108](108_DISENO_PERSISTENCIA_CUOTAS_SALDO_CANONICO.md). Cierre parcial: falta prueba real de interacción; no se ejecutó Flutter en esta entrega. **Dependencia:** conservar contratos actuales; decisiones de fase 0 para extensiones futuras.

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

El CTA **Histórico financiero** ya está implementado; conservarlo y verificar su navegación.

Debe abrir directamente `Reportes > Financiero`.

## 5.3 Criterios de aceptación

- Balance continúa limitado al día actual.
- No se agregan gráficos históricos a Balance.
- Histórico financiero abre Reportes > Financiero.
- No se duplica el selector de Rendimiento de Inicio.

## 5.4 Contrato de navegación existente

Conservar ReportesInitialContext y sus pruebas: pestaña, filtro financiero, período, fecha y rango. Cubrir apertura real de pantalla y aplicación de filtros, además del mapeo de valores. Facturación y filtros fiscales se añaden en las fases 6 y 7, cuando exista su contrato.

**Salida:** Balance diario y contexto inicial de las dos pestañas actuales verificados; no declarar completa la navegación fiscal futura.

# 6. Fase 2 — Base canónica de deuda, cuotas y cobros

**Estado actualizado (2026-11-03, America/Lima):** base financiera 2A/2B, cobros y cuotas 2C1–2C4, reverso de transferencia 2C5A, expediente 2C5B-A, integración atómica NC/baja 2C6A–2C6B y reserva/liquidación/retorno 2C5B-B completados en el backend. El último bloque superó [CI 41752361125](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41752361125) **7/7** y se desplegó en **Supabase DEV** como migración `20261104010306_financial_2c5b_refund_settlement.sql`, con **49/49 comprobaciones reversibles** (32 de banco y 17 de caja) y nueve carreras concurrentes en CI. Solo se registra evidencia de desembolso aportada por operador: NO se envían transferencias reales, NO hay RPC/UI cliente ni producción habilitados. **La fase 2 no se declara terminada globalmente:** quedan la integración de creación v5 con cuotas versionadas (2D), reversos de cobros en efectivo y pruebas completas de lectura/reportes. La fase 3 de crédito electrónico sigue bloqueada hasta cumplir backend, condiciones SUNAT y emisión. Ver [diseño 108](108_DISENO_PERSISTENCIA_CUOTAS_SALDO_CANONICO.md) y [contrato 107](107_CONTRATO_FINANCIERO_CREDITO_CUOTAS_AJUSTES.md).

**2D-A implementado y validado en CI (2026-11-03):** escritor `process_sale_credit_v5` con cronograma v1, cuotas persistentes, apertura contable y abono inicial de transferencia exacto; Flutter propaga `creditTerms`. La migración `20261104025000` está desplegada en Supabase DEV, 23/23 pruebas SQL reversibles pasaron y [CI 41766118344](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41766118344) terminó **7/7 SUCCESS** (source `b6bb5e6`, espejo `7f19f3b`). **La fase 2D sigue abierta:** falta la prueba E2E positiva de venta/stock/abono/cuotas y la lectura autorizada, así como revisión del RPC privilegiado antes de producción. Las integraciones SUNAT y la UI de crédito electrónico son de fase 3. Véase sección 26 del documento 108.

**2D-B cerrado técnicamente en DEV (2026-11-04):** migración `20261104174500` aplicada, lector de cuotas `SECURITY INVOKER` con aislamiento tenant/RLS y Flutter integrado. **31/31 pruebas pgTAP en DEV** (lector 10, ventas reales sintéticas E2E 21), con abono inicial, idempotencia, inventario, presentaciones configuradas 1 caja=2 unidades, asignación de cobro posterior S/50 y reverso compensatorio. [CI 41896721219](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41896721219): **7/7 SUCCESS** (source `71ab4159`, espejo `fa62afbf`). Se corrigió el instalador PGDG para fallos temporales de red. **Pendiente fuera de 2D-B:** contrato y pruebas de reverso del abono *inicial*, revisión del escritor financiero v5 `SECURITY DEFINER` y de evidencias bancarias antes de cualquier operación comercial. **Solo desarrollo; prohibido desplegar en producción o habilitar SUNAT crédito.** Véase documento 108 sección 27.

**2D-C candidato técnico (solo DEV):** migración `20261104212500` con reverso interno del abono inicial por transferencia de v5 (sin egreso bancario), evento compensatorio y cronograma versión 2. Impide reversión con cobros posteriores u operaciones ajenas, exige actor y permiso `sales.collect`, y mantiene v1 inmutable. El asignador de cuotas y el reversor de cobros posteriores admiten exclusivamente v2 de procedencia certificada. **51/51 aserciones pgTAP reversibles aprobadas en Supabase DEV** (20 nuevas y regresiones 21+10). Pendiente CI 7/7, despliegue persistente únicamente en DEV y validación bancaria externa. No producción, no SUNAT crédito, no UI de reverso del anticipo. Véase documento 108 §28.

Antes de construir estadísticas finales, unificar la forma en la que StOmni calcula cuánto debe realmente un cliente.

Actualmente partes del dominio calculan saldo desde `ventas.total - pagos_venta`. Ese cálculo no es suficiente una vez que existen NC y ND.

## 6.1 Fórmula canónica

Definir server-side:

`Monto exigible = Venta original - NC monetarias aceptadas + ND aceptadas`

y:

`Saldo neto = Monto exigible - cobros netos aplicados`

`Saldo pendiente = max(Saldo neto, 0)`

`Excedente a favor = max(-Saldo neto, 0)`

Los cobros netos aplicados deben conservar pagos, reversos y devoluciones según la política cerrada en fase 0. El excedente es una obligación trazable, no un valor descartable.

La definición exacta deberá excluir documentos:

- rechazados;
- pendientes;
- anulados/baja aceptada;
- que no afecten dinero.

## 6.2 Venta original inmutable

No aumentar ni disminuir `ventas.total` por NC/ND.

`ventas.total` debe seguir representando la operación original.

Los ajustes fiscales se mantienen separados y se reflejan mediante el cálculo canónico de monto exigible.

## 6.3 Integración con cuotas

Cuando cambie el monto exigible por una NC/ND aceptada:

- recalcular saldo pendiente;
- reconciliar cronograma de cuotas;
- no perder pagos ya aplicados;
- no mostrar deuda negativa ni perder el excedente a favor del cliente;
- volver a abrir una deuda si una ND crea nuevo pendiente;
- ajustar o cerrar cuotas según reglas explícitas y auditables.

La política definida en el contrato 107 (cobros por vencimiento ascendente, NC desde saldos más lejanos, ND como obligación adicional y reversos auditables) deberá implementarse centralizada en backend y cubrirse por pruebas.

## 6.4 Integración con pagos

El RPC de cobro no deberá validar únicamente contra `ventas.saldo` derivado del total original.

Deberá usar la fuente canónica de saldo exigible y mantener:

- bloqueo transaccional;
- idempotencia;
- validación de sobrepago;
- asignación a cuotas;
- actualización de estado de deuda.

## 6.5 Reportes y Balance

**Balance** representa efectivo:

- pagos efectivamente cobrados;
- egresos efectivamente realizados.

**Facturación** representa documentos fiscales emitidos/aceptados según la definición del reporte.

**Cuentas por cobrar** representa saldo exigible todavía no cobrado.

No mezclar estas tres magnitudes.

## 6.6 Criterios de aceptación

- NC aceptada reduce monto exigible.
- ND aceptada aumenta monto exigible.
- Un documento pendiente/rechazado no altera deuda.
- Los pagos reducen únicamente saldo pendiente.
- No se modifica el total original de la venta.
- Una venta pagada puede reabrirse como deuda tras ND aceptada.
- No existe sobrepago por carrera concurrente.

## 6.7 Persistencia y compatibilidad antes de habilitar crédito

Diseñar y crear el cronograma tenant-aware descrito en la fase 3, con claves/relaciones por organización, RLS, permisos y auditoría. Definir asignaciones de pagos y ajustes auditables. Migrar/reconciliar datos antiguos sin inventar vencimientos ni perder cobros.

Implementar el contrato canónico sobre operaciones existentes y probar el efecto de ND mediante casos de contrato; no anunciar soporte ND real hasta completar su modelo, emisión y reconciliación en fase 4.

**Salida:** persistencia de cuotas, cobros y NC existentes integrada y probada; contrato de ND definido; sobrepago y excedentes cubiertos. La habilitación comercial permanece condicionada a la fase 3.

# 7. Fase 3 — Venta electrónica a crédito de extremo a extremo

**Estado:** parcial en modelos y cola offline; flujo funcional pendiente. **Dependencia:** fase 2 y reglas fiscales verificadas.

La venta a crédito ya existe en StOmni para Ticket Interno, pero actualmente la UI y la política fiscal fuerzan el uso de `ticket_interno` cuando la venta es crédito.

El objetivo de esta fase es permitir también:

- Factura electrónica al contado;
- Factura electrónica a crédito;
- Boleta electrónica al contado;
- Boleta electrónica a crédito;
- Ticket interno al contado;
- Ticket interno a crédito.

La Nota de débito no formará parte del selector de comprobante de una venta nueva. Es un documento fiscal posterior que modifica un comprobante ya emitido.

## 7.1 Cambios en Procesar venta

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

## 7.2 Condiciones de pago

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

La suma de cuotas deberá ser exactamente igual al monto pendiente normalizado en centavos; tolerancia económica cero en el contrato nuevo, conforme al documento 107.

## 7.3 Modelo de cuotas

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
- anulada/invalidada por ajuste cuando corresponda.

Vencida es una condición adicional calculada por saldo y fecha local, compatible con parcialmente pagada; no reemplaza el estado de liquidación.

## 7.4 Política fiscal

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

## 7.5 Backend de venta

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

## 7.6 Emisión SUNAT de crédito

El generador fiscal actual construye los comprobantes con forma de pago `Contado`.

Debe ampliarse para generar correctamente la modalidad:

- Contado;
- Crédito.

Para Crédito deberá incluir en el XML/contrato fiscal vigente:

- monto neto pendiente;
- vencimiento cuando corresponda;
- cuotas con monto y fecha cuando existan.

La implementación deberá validarse contra el catálogo y especificación SUNAT vigentes al momento de desarrollar esta fase.

## 7.7 Balance

Una venta a crédito no debe contabilizar el total facturado como ingreso de caja.

Ejemplo:

`Factura S/ 1,000 · Abono inicial S/ 200 · Pendiente S/ 800`

Balance registra hoy únicamente:

`Ingreso real: S/ 200`

Los S/ 800 restantes aparecerán en cuentas por cobrar y sólo entrarán a Balance cuando sean efectivamente pagados.

## 7.8 Deudas y cobros

Los cobros posteriores deberán:

- registrar `pagos_venta`;
- reducir el saldo exigible;
- aplicar el pago a las cuotas correspondientes;
- actualizar estados de cuota;
- detectar vencidas;
- conservar idempotencia.

Una venta completamente pagada podrá volver a tener saldo pendiente si posteriormente una Nota de débito aceptada incrementa el monto exigible.

## 7.9 Criterios de aceptación

- Crédito no fuerza Ticket Interno.
- Factura y Boleta pueden emitirse correctamente a crédito.
- El abono inicial se registra como ingreso real.
- El saldo no pagado no aparece como caja.
- Pago único y múltiples cuotas son soportados.
- Las cuotas son tenant-aware.
- El XML fiscal representa correctamente Contado/Crédito.
- El flujo conserva idempotencia y aislamiento por empresa.

## 7.10 Secuencia de implementación y salida

1. Reutilizar los modelos y la cola versión 3 ya existentes; completar validaciones conforme a la fase 0.
2. Conectar creditTerms desde VentaProcessingRequest a _VentaProcessingRepositoryAdapter, VentasRepository y RPC; demostrar lectura posterior del mismo cronograma.
3. Integrar venta, abono, cuotas, stock y comprobante de forma atómica, con retries idempotentes y validación server-side.
4. Adaptar emisión Contado/Crédito y verificar XML, respuestas y recuperación de resultado incierto.
5. Completar formulario de pago único/múltiples cuotas y retirar los bloqueos de UI/política solo cuando backend y emisión estén listos.
6. Probar el recorrido real UI → RPC → cuotas → emisión → cobros → Balance, incluida compatibilidad con tickets offline existentes.

**Salida:** criterios 7.9 cumplidos con evidencia integrada; no basta un test con gateway simulado. La emisión electrónica offline sigue restringida.

# 8. Fase 4 — Nota de débito e integración de ajustes

**Estado:** pendiente. **Dependencia:** fases 2 y 3. Integrar ND aceptada con el contrato canónico antes de exponerla como funcionalidad completa.

La Nota de débito se implementará como un documento fiscal posterior asociado a una Factura o Boleta existente.

No será un nuevo tipo de venta ni aparecerá como opción al crear una venta.

## 8.1 Origen y elegibilidad

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

## 8.2 Modelo fiscal

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

## 8.3 Series y correlativos

Añadir soporte de serie/correlativo de Nota de débito dentro del namespace del tenant.

No compartir correlativos globales entre empresas.

La serie deberá configurarse por organización igual que el resto de documentos fiscales.

## 8.4 RPC y seguridad

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

## 8.5 Edge Functions y emisión

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

## 8.6 Core logic y móvil

Agregar:

- modelo/record de Nota de débito;
- repository/use case;
- métodos de FacturacionService;
- pantalla Emitir Nota de débito;
- pantalla Ver Nota de débito;
- estados, errores y reintentos;
- listado de ND relacionadas en Ver Venta.

El detalle de una venta deberá mostrar claramente NC y ND relacionadas sin alterar el total original almacenado de la venta.

## 8.7 Stock

Por defecto, una Nota de débito es un ajuste monetario/fiscal y no debe consumir ni reponer stock automáticamente.

Cualquier supuesto futuro que requiera efecto de inventario deberá tener un contrato explícito y pruebas propias; no reutilizar ciegamente la lógica de Nota de crédito.

## 8.8 Gestión SUNAT

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

## 8.9 Criterios de aceptación

- ND sólo nace desde un comprobante compatible.
- ND tiene serie/correlativo por empresa.
- ND tiene idempotencia.
- ND puede emitirse, consultarse y reintentarse.
- ND no altera stock automáticamente.
- ND aparece en Gestión SUNAT y detalle de venta.
- Aislamiento ORG_A/ORG_B probado.

## 8.10 Cierre financiero de ND

Conectar aceptación, rechazo, resultado incierto y baja con deuda/cuotas mediante transiciones idempotentes. Probar reapertura de deuda pagada, ajuste de cronograma sin perder pagos, concurrencia y total original inmutable. Sustituir los casos de contrato de ND de fase 2 por pruebas con documentos persistidos y resultados de emisión.

**Salida:** DB/RLS/RPC, emisión, CDR, UI y efectos financieros completos; un reintento no duplica correlativo, documento ni ajuste.

# 9. Fase 5 — Agregados históricos de facturación

**Estado:** pendiente. **Dependencia:** fases 2–4 y definiciones temporales/monetarias de fase 0.

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

## 9.1 Fórmula de facturación neta

Conceptualmente:

`Facturación neta = Facturas + Boletas - NC monetarias aceptadas + ND aceptadas`

La implementación deberá definir con precisión:

- fecha usada para cada documento;
- tratamiento de bajas;
- documentos pendientes/rechazados;
- moneda;
- redondeos;
- notas que no afectan dinero.

## 9.2 Requisitos

- tenant actual derivado del contexto autenticado;
- sin posibilidad de consultar otra organización;
- permisos/capabilities respetados;
- rangos validados;
- no exponer payload tributario sensible innecesario;
- respuesta adecuada para gráficos sin descargar miles de documentos;
- no usar resultados paginados de Gestión SUNAT como fuente de agregación.

## 9.3 Pruebas

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

# 10. Fase 6 — Reorganización de Reportes

**Estado:** parcial en contexto inicial; tercera pestaña pendiente. **Dependencia:** fase 5. La fase 7 completa el contenido de Facturación.

Convertir Reportes en el centro de análisis histórico.

Nueva estructura: **Financiero | Inventario | Facturación**.

## 10.1 Filtros globales

Mantener Diario, Semanal, Mensual, Anual y Personalizado.

Reportes deberá poder recibir contexto inicial desde otras pantallas:

- pestaña;
- período;
- fecha/rango;
- tipo financiero;
- tipo de documento o estado cuando corresponda.

## 10.2 Reportes > Financiero

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

## 10.3 Reportes > Inventario

Mantener entradas, salidas, traslados, filtros por producto, histórico de movimientos y exportaciones actuales.

## 10.4 Criterios de aceptación

- Reportes tiene tres pestañas.
- Puede abrir en una pestaña, filtro y período específicos.
- Los filtros globales son consistentes entre las tres pestañas.
- El contexto recibido desde Inicio o Balance se respeta al abrir.

# 11. Fase 7 — Reportes > Facturación

**Estado:** pendiente. **Dependencia:** fases 5 y 6. El recorrido a Gestión SUNAT se cierra en fases 8–9.

Esta sección será exclusivamente analítica.

## 11.1 KPIs por período

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

## 11.2 Reglas monetarias

- Facturas y Boletas forman parte del importe fiscal.
- NC monetarias aceptadas reducen facturación neta.
- ND aceptadas incrementan facturación neta.
- GRE no suma importe de venta.
- una venta a crédito puede estar facturada sin haber sido cobrada;
- Balance no debe copiar el total facturado como ingreso.

## 11.3 Gráficos

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

## 11.4 Drill-down

Ejemplos:

- tocar `3 rechazados` -> Gestión SUNAT filtrada por rechazados y mismo período;
- tocar `58 Facturas` -> Gestión SUNAT filtrada por Facturas y mismo período;
- tocar `4 Notas de débito` -> Gestión SUNAT filtrada por ND;
- tocar `17 Guías` -> Gestión SUNAT filtrada por GRE y mismo período.

## 11.5 Criterios de aceptación

- Las estadísticas son completas para todo el período.
- NC y ND afectan correctamente facturación neta.
- Crédito no se confunde con efectivo cobrado.
- GRE no afecta el total facturado.
- Los estados tributarios son navegables hacia Gestión SUNAT.

# 12. Fase 8 — Renombrar Documentos electrónicos a Gestión SUNAT

**Estado:** pendiente. **Dependencia:** fase 4 para incluir ND.

En Centro de trabajo, **Documentos** pasa a **Gestión SUNAT**.

Subtítulo recomendado: `Comprobantes, envíos, consultas y bajas`.

La pantalla mantiene su función operativa.

## 12.1 Mantener y ampliar

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

## 12.2 No convertir en reporte

Gestión SUNAT no calculará facturación histórica, evolución por período ni KPIs agregados.

Eso pertenece a Reportes > Facturación.

# 13. Fase 9 — UX operativa de Gestión SUNAT

**Estado:** pendiente. **Dependencia:** fases 7 y 8.

## 13.1 Filtros operativos

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

## 13.2 Jerarquía visual

Los documentos problemáticos deben destacar más que los aceptados. Un documento rechazado debe mostrar claramente el motivo y la acción de reintento; un documento aceptado puede mostrarse de forma más discreta.

## 13.3 Acceso a análisis

Agregar **Ver reporte de facturación**, que abre `Reportes > Facturación` con el período actual cuando aplique.

# 14. Fase 10 — Indicadores y filtros de Inventario

**Estado:** pendiente de implementación/verificación del bloque completo. **Dependencia:** contratos de permisos actuales. Coordinar el traslado con fase 11 para no perder el acceso a indicadores.

Mover el contador de productos registrados desde Inicio hacia Inventario.

## 14.1 Resumen superior

Agregar un resumen compacto, sin una gran card contenedora:

- Productos
- Stock bajo
- Sin stock

Ejemplo conceptual: `428 productos · 17 stock bajo · 3 sin stock`.

## 14.2 Indicadores interactivos

- tocar Productos -> mostrar todos;
- tocar Stock bajo -> aplicar filtro de stock bajo;
- tocar Sin stock -> aplicar filtro de agotados.

## 14.3 Criterios de aceptación

- El total de productos ya no aparece en Inicio.
- Inventario muestra total de productos, stock bajo y agotados.
- Los indicadores aplican filtros reales.
- No se altera el flujo actual de creación, edición o consulta de productos.

# 15. Fase 11 — Reestructuración de Inicio

**Estado:** pendiente. **Dependencia:** fases 5–10; las métricas y destinos deben estar disponibles.

## 15.1 Eliminar duplicaciones

Retirar de Inicio:

- cantidad total de productos registrados;
- cards de Ventas de hoy;
- cards de Egresos de hoy;
- Flujo neto como métrica independiente;
- actividad reciente de ventas/egresos que duplique Balance;
- la card contenedora grande que agrupa otras cards cuando no agrega jerarquía útil.

Balance ya cubre la actividad financiera diaria.

## 15.2 Nueva sección Rendimiento

Crear una sección visual plana con selector principal:

- Cobros
- Egresos
- Facturación

Selector temporal:

- 7 días
- 30 días
- Mes
- Año

Se mostrará un único gráfico que cambia según la selección.

### Cobros

Mostrar tendencia histórica de dinero cobrado conforme al contrato 107, distinguiendo reversos y devoluciones. No usar ventas realizadas como sustituto de ingresos.

### Egresos

Recuperar el gráfico histórico de egresos que existía anteriormente.

### Facturación

Mostrar evolución de facturación electrónica, separando principalmente Boletas y Facturas. No incluir GRE dentro del importe facturado.

## 15.3 CTA de Inicio

El CTA recomendado será **Analizar período**.

Comportamiento:

- Cobros + período -> Reportes > Financiero > Ingresos + mismo período. La métrica representa dinero cobrado, no ventas realizadas.
- Egresos + período -> Reportes > Financiero > Egresos + mismo período.
- Facturación + período -> Reportes > Facturación + mismo período.

## 15.4 Alertas

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

## 15.5 Criterios de aceptación

- Inicio no duplica Ventas/Egresos/Neto de hoy.
- Inicio no muestra el total de productos registrados.
- Existe un único gráfico de Rendimiento.
- Cobros, Egresos y Facturación comparten la misma zona visual.
- El período seleccionado se conserva al navegar a Reportes.
- Alertas contiene únicamente elementos accionables.
- No existen cards decorativas anidadas innecesariamente.

# 16. Fase 12 — Navegación cruzada completa

**Estado:** parcial solo en Balance → Financiero. **Dependencia:** fases 7–11.

## Inicio -> Reportes

- Cobros -> Financiero / Ingresos. Ventas realizadas es una métrica distinta y queda fuera de este selector.
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

# 17. Fase 13 — Unificación visual móvil

**Estado:** existe trabajo visual previo; cierre conjunto pendiente. **Dependencia:** flujos de fases 3–12. Aplicar coherencia visual también durante cada entrega.

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

# 18. Fase 14 — Regresión integrada, CI y QA

**Estado:** CI de la línea base verde; cierre del roadmap pendiente. **Dependencia:** todas las fases funcionales. Las pruebas unitarias, de integración y seguridad se ejecutan también en cada fase.

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

## 18.1 Evidencia por entrega

- Registrar SHA privado y SHA del espejo con correspondencia verificable.
- Ejecutar formato, análisis y pruebas afectadas; incluir pruebas reales de persistencia y transacciones para crédito/ajustes.
- Exigir aislamiento ORG_A/ORG_B, reintentos y concurrencia; complementar pruebas estáticas con integración y recorridos móviles.
- Obtener validación completa 7/7 del candidato.
- Generar QA únicamente después de CI verde desde el SHA privado validado; registrar build, SHA y resultado de revisión.
- CI verde de la base no cierra requisitos aún no implementados. No desplegar a producción como parte de este roadmap.

# 19. Ruta de ejecución y actualización de estado

La ruta única es: fase 0 (decisiones) → fase 1 (consolidar base de navegación) → fase 2 (deuda/cuotas/cobros) → fase 3 (crédito completo) → fase 4 (ND integrada) → fase 5 (agregados) → fases 6–7 (Reportes) → fases 8–9 (Gestión SUNAT) → fases 10–11 (Inventario e Inicio) → fase 12 (navegación cruzada) → fase 13 (cierre visual) → fase 14 (regresión y QA).

2C6B y 2C5B-B cerrados y desplegados en DEV (CI 41711330018 y 41752361125, ambos 7/7). 2D-A implementado, probado en CI 41766118344 (7/7), migración v5 desplegada en DEV. **Próximo paso: 2D-B**, lectura protegida de cronogramas y E2E positivo de venta a crédito con inventario, abono y cuotas, antes de habilitar en producto; resolver la revisión de SECURITY DEFINER. Sigue pendiente la prueba de navegación de fase 1. No empezar por rediseñar Inicio ni habilitar crédito electrónico SUNAT en UI.

Actualizar la tabla de línea base y añadir evidencia al cierre de cada fase. Usar los estados pendiente, parcial, implementado y validado; implementado sin evidencia integrada no equivale a validado. Los requisitos fiscales solo se consideran verificados después de contrastar las especificaciones vigentes y probar su implementación.

# 20. Fuera de alcance

- rediseño completo de escritorio;
- cambios generales de core business no relacionados;
- cambios de precios/suscripciones;
- despliegue a producción;
- eliminación de Gestión SUNAT;
- uso de GRE como ingreso financiero;
- contabilizar una Factura/Boleta a crédito como efectivo antes del cobro;
- tratar Nota de débito como una venta nueva;
- modificar stock automáticamente por una ND sin contrato explícito.

# 21. Definición de terminado

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

