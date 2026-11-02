# Contrato financiero — Crédito, cuotas, cobros y ajustes

Fecha: 2026-11-02 (America/Lima).
Roadmap: [106](106_ROADMAP_MOBILE_HOME_REPORTES_GESTION_SUNAT.md), fase 0.
Base de código revisada: `37c4f3869432151857ef73cca77debc12feb307f`.

**Estado:** decisiones financieras de implementación definidas; pendientes de implementación y pruebas integradas. No constituye certificación SUNAT ni confirma el estado de la base desplegada. La verificación normativa de crédito y ND es un gate obligatorio de las fases 3 y 4, antes de habilitar emisión.

## 1. Evidencia y alcance

- `packages/core_logic/lib/features/ventas/data/ventas_repository.dart`: processSaleRpc llama process_sale_v4/process_sale_with_units_v4 sin cronograma. También existe conversión de cotización a ticket a crédito sin cuotas.
- `packages/core_logic/lib/features/deudas/data/deudas_repository.dart`: cobros mediante procesar_pago_deuda_v2; preserva request_id ante resultado incierto.
- `supabase/migrations/20260908033500_saas_cash_debt_and_expense_runtime.sql`: el RPC bloquea venta y protege solicitudes por tenant, pero recalcula saldo como total menos pagos y usa tolerancias de centavos.
- `supabase/migrations/RPCs/nota_credito_finalizar.sql`: agrega NC monetarias aceptadas, excluye baja aceptada y actualiza monto_notas_credito/estado_tributario. Este archivo es evidencia del repositorio; no se asume que sea la última definición desplegada.
- El modelo Dart de cuotas ya existe, pero la propagación hasta DB no está completa.

Estas reglas cubren cuentas por cobrar de ventas. No cambian automáticamente deudas de proveedores, nómina ni contabilidad general. Antes de una migración se inspeccionarán las definiciones efectivas, triggers y datos en el entorno objetivo.

## 2. Diccionario único de métricas

| Concepto | Definición y fecha |
|---|---|
| Ventas realizadas | Operaciones comerciales por fecha de venta; separar importe original de ajustes. No equivale a cobros ni exige que el documento fiscal esté aceptado. |
| Ingresos/Cobros | Dinero efectivamente recibido por fecha de cobro, con reversos y devoluciones identificados. Incluye medios distintos de efectivo físico. |
| Balance diario | Cobros netos y egresos del día; no suma el saldo no cobrado de una venta. Caja física se filtra por método/sesión. |
| Facturación neta | Facturas y boletas aceptadas menos NC monetarias aceptadas más ND aceptadas, excluyendo bajas aceptadas. Los pendientes/rechazados se muestran por separado, no en el total aceptado. |
| Cuentas por cobrar actuales | Suma de saldos exigibles actuales, sin compensar excedentes entre clientes o ventas. |
| Saldo actual de ventas del período | Ventas seleccionadas por fecha original y saldo calculado hoy; debe etiquetarse de ese modo. |
| Saldo al cierre histórico | Reconstrucción de eventos hasta el corte; no se ofrece como si fuera el saldo actual. No habilitar sin historial suficiente. |
| GRE | Conteo operativo; nunca importe monetario facturado. |

**Decisión de navegación:** en Inicio el selector financiero será **Cobros / Egresos / Facturación**, porque el destino Financiero/Ingresos representa dinero cobrado. Si se incorpora posteriormente una serie de ventas realizadas, tendrá nombre y destino propios. Mantener “Ventas” para el módulo comercial.

## 3. Tiempo, moneda y precisión

- Fechas operativas en America/Lima. Persistir instantes con zona y fechas de vencimiento como date, sin convertirlas inadvertidamente por UTC.
- Rangos temporales semiabiertos: inicio incluido, comienzo del día posterior al final excluido. Semanas de lunes a domingo; Mes/Año son calendario; 7/30 días incluyen hoy y los 6/29 días previos.
- Para facturación por período se usa fecha de emisión de cada documento y estado efectivo actual. NC/ND se imputan a su propia fecha, no reescriben la fecha de venta. Mostrar “según estado actual”; aceptación tardía o baja puede modificar una consulta retrospectiva.
- Registrar además fecha efectiva y fecha de registro de cada transición para futura reconstrucción al corte. Una fecha comercial retroactiva no puede usarse para falsificar qué se conocía en un cierre.
- Este bloque utiliza PEN para los nuevos flujos de cuotas. Detectar moneda real existente antes de migrar. Si hay otras monedas, conservarlas y bloquear su conversión automática; reportar por moneda sin sumarlas ni convertirlas implícitamente.
- Importes monetarios canónicos en decimal exacto con dos decimales, representables como centavos enteros en contratos y pruebas. No usar double como autoridad.
- Precios unitarios/impuestos pueden necesitar mayor precisión; conservarla según el contrato fiscal, redondeando únicamente en límites definidos. No reducir globalmente la precisión de cantidades o precios.
- Nuevos importes de pagos/cuotas deben ser finitos, positivos y de dos decimales. Tras normalización acordada del transporte, suma de cuotas = saldo exactamente: tolerancia económica **0 centavos**. No aceptar sobrepagos de 0.01.
- División automática: repartir centavos enteros; el residuo se asigna a la última cuota. Ejemplo: 100/3 = 33.33, 33.33, 33.34.
- No redondear silenciosamente datos heredados discrepantes. Registrar diferencias y resolverlas mediante reconciliación auditable antes de habilitar el contrato nuevo.

## 4. Saldo canónico y excedentes

Por venta y moneda:

`Exigible E = total original - NC monetarias efectivas + ND monetarias efectivas`

`Cobros netos C = cobros confirmados - reversos confirmados - devoluciones efectivas`

`Saldo neto N = E - C`

`Pendiente D = max(N, 0)`

`Excedente F = max(-N, 0)`

Invariantes: E >= 0, C >= 0, D y F no son simultáneamente positivos, y E + F = C + D. No modificar ventas.total para representar NC/ND. Los campos saldo/estado de ventas, si se mantienen por compatibilidad, son proyecciones de este cálculo.

- Un cobro nuevo ordinario debe ser <= D. Los anticipos ajenos a una venta quedan fuera de alcance.
- NC/ND pendientes, rechazadas o inciertas no afectan E. Aceptación aplica una sola vez; baja aceptada revierte una sola vez el ajuste correspondiente cuando ese procedimiento sea fiscalmente válido.
- Un ajuste que dejaría E negativo no puede crearse por los entrypoints internos. Si llega un resultado externo contradictorio ya aceptado, conservar el documento y poner la conciliación en revisión; no descartar ni alterar la respuesta fiscal.
- ND aceptada usa primero cualquier excedente de esa misma venta mediante el cálculo neto; solo reabre deuda por el remanente.
- El excedente permanece identificado por tenant, cliente, venta y moneda. **No se compensa automáticamente con otra venta.** La transferencia entre ventas queda fuera de esta entrega.
- La devolución requiere operación explícita autorizada, request_id, medio, referencia y fecha; importe <= excedente disponible bajo bloqueo. Solo al confirmarse reduce C y genera la salida real de dinero.
- Ejemplo: venta 1,000 cobrada; NC 200 → E=800, C=1,000, D=0, F=200. Devolver 200 → E=800, C=800, D=0, F=0. La NC no es por sí misma un egreso de caja.
- Reversar un pago significa corregir un registro que no representa dinero válido; devolver significa una salida real. Son eventos diferentes y no deben duplicar la misma reducción de C.
- Conservar pagos originales y registrar eventos compensatorios; no borrar historia mediante eliminar_pago_venta_v1 en el contrato nuevo. Adaptar todos sus consumidores antes de habilitarlo.
- Anulación de venta y baja de comprobante no se tratarán como borrado ni como devolución automática. Para venta electrónica, la baja del documento no extingue por sí sola la obligación comercial: debe existir el ajuste/cancelación comercial explícito y auditable. Cancelación de ticket puede llevar E a cero mediante evento propio, preservando excedentes.

## 5. Cronograma y aplicación de cobros

- Venta nueva a crédito: 0 <= abono < total, saldo > 0; método obligatorio si abono > 0. Abono = total corresponde a contado.
- Cronograma obligatorio en nuevas ventas a crédito del contrato nuevo: una cuota o varias, numeración consecutiva desde 1, importes positivos, fechas no decrecientes y posteriores a fecha de venta. Se permiten cuotas en el mismo día.
- La suma inicial del cronograma representa el saldo después del abono. El abono inicial no vuelve a aplicarse a las cuotas.
- Registrar asignaciones pago-cuota auditables; un pago puede cubrir varias cuotas y una cuota varios pagos.
- Cobros posteriores se aplican por fecha de vencimiento ascendente y después número de cuota; cubren cuotas futuras si las anteriores ya están cubiertas. No hay selección discrecional ni intereses automáticos en esta entrega.
- Estado de liquidación: pendiente, parcial, pagada o cancelada por ajuste. “Vencida” es condición adicional: saldo > 0 y vencimiento < fecha local actual; una cuota parcial puede estar vencida. No vence al inicio del propio día de vencimiento.
- Ajustes no sobrescriben el cronograma original: mantener versiones y detalle de cómo se llegó al cronograma vigente.

### 5.1 Redistribución de ajustes

- NC monetaria efectiva: reducir primero saldo no pagado desde la cuota de vencimiento más lejano, con número descendente para empates. Mantener las fechas de las cuotas restantes.
- Si la NC excede la deuda no pagada, registrar la porción que libera cobros como excedente; conservar asignaciones históricas y sus reclasificaciones, sin inventar un nuevo cobro ni devolver automáticamente.
- ND: aumento neto pendiente se registra como obligación adicional asociada a la ND, con vencimiento explícito capturado antes de emitir y validado conforme al contrato fiscal. No redistribuirla silenciosamente en cuotas antiguas ni inventar vencimiento.
- Si el efecto de ND queda absorbido totalmente por excedente, registrar esa absorción y no crear cuota positiva artificial.
- Baja/reversión de ajuste restaura su efecto con un evento compensatorio y recalcula sobre la situación actual, sin borrar pagos posteriores. Conservar el vencimiento original de la obligación restaurada; puede quedar vencida.
- Reverso parcial/total de un pago deshace sus asignaciones en orden inverso al que se aplicaron, reabriendo las mismas cuotas; no reasigna cronológicamente todos los pagos históricos.
- Todas las transformaciones deben conservar: suma del saldo de obligaciones vigentes = D. Si un evento externo no trae datos suficientes para distribuir, mantener D canónico y señalar “pendiente de conciliación”, bloqueando nueva emisión/ajustes dependientes hasta resolverlo; nunca ocultar la deuda.

## 6. Atomicidad, idempotencia y aislamiento

- Venta, abono, deuda, cuotas y stock se crean en una transacción local de base de datos. Una llamada externa a SUNAT no forma parte de esa transacción: emisión posterior durable, con estados, intentos y reconciliación de resultado incierto.
- Todo cobro/devolución/ajuste recalcula sobre saldo autoritativo bajo bloqueo; Flutter no decide el saldo válido.
- Request_id por organización y tipo de operación; mismo ID y mismo payload devuelve resultado original; distinto payload produce conflicto. Incluir moneda, origen, importe, método y fechas económicas en el contrato nuevo.
- Un evento fiscal externo usa identidad estable de documento y transición para impedir doble efecto por callbacks/reintentos.
- Definir un orden global de bloqueos compartido por venta, caja, cobros, devoluciones y ajustes; verificarlo contra los RPC existentes antes de implementar. Probar deadlocks/reintentos además de doble cobro.
- Derivar organización del contexto autenticado, comprobar permisos y relaciones compuestas tenant-aware; RLS y acceso mínimo en nuevos objetos. Un cliente de ORG_A no puede consultar, ajustar ni cobrar una venta de ORG_B.
- Contabilidad de caja: efectivo requiere sesión permitida; transferencias/tarjetas no se contabilizan como efectivo físico. Mantener las reglas actuales de caja hasta extenderlas de forma explícita y probada.

## 7. Compatibilidad y migración

1. Inventariar funciones/triggers efectivos y todos los escritores: venta normal, unidades, cotización, offline, NC, baja, anulación, cobros y eliminación de pagos.
2. Comparar por tenant y moneda total, pagos, ajustes, saldo almacenado y saldo canónico. No corregir diferencias masivamente sin evidencia.
3. Crear estructuras aditivas y contratos versionados compatibles. Mantener tickets antiguos en cola sin perder request_id; payload futuro desconocido se rechaza de forma recuperable.
4. Ventas históricas sin fecha contractual quedan como “sin cronograma/vencimiento conocido”; no marcarlas vencidas por una fecha inventada. Su saldo puede cobrarse y debe aparecer en agregado separado.
5. Clientes/colas antiguos pueden seguir el contrato legado autorizado, sin exigir un cronograma que nunca capturaron. Nuevas capacidades se habilitan solo para versión de cliente compatible. No habilitar crédito electrónico por el camino legado.
6. Contrastar en paralelo proyección nueva y anterior; resolver diferencias. Activación controlada por capacidad/versión y evidencia de integración.
7. Rollback deshabilita nuevas escrituras/capacidades, preserva historia y no elimina tablas ni pagos. Una vez existan ND/ajustes nuevos no volver a servir “total - pagos” como saldo autoritativo.
8. Cualquier reconstrucción al cierre anterior a la disponibilidad de eventos debe declararse no disponible o incompleta, no estimarse silenciosamente.

## 8. Matriz de aceptación

Resultados en PEN; fixtures independientes salvo secuencia explícita. E=exigible, C=cobros netos, D=deuda, F=excedente.

| ID | Escenario | Resultado obligatorio |
|---|---|---|
| F01 | Venta 1,000; abono 200; cuotas 400+400 | E=1,000; C=200; D=800; F=0; ingreso del día 200. |
| F02 | Sobre F01 cobrar 150 | C=350; D=650; cuotas pendientes 250+400. |
| F03 | Repetir solicitud F02 | Mismo pago/resultado, sin nuevo ingreso ni asignación. |
| F04 | Reutilizar ID F02 cambiando importe/fecha económica | Conflicto; sin modificación. |
| F05 | F01: NC aceptada 300 | E=700; C=200; D=500; cuotas 400+100. |
| F06 | Venta 1,000 totalmente cobrada; NC 200 | E=800; C=1,000; D=0; F=200; sin salida de caja. |
| F07 | F06: devolver 200 | E=800; C=800; D=0; F=0; salida real 200 una sola vez. |
| F08 | Venta 1,000 cobrada; ND aceptada 100 | E=1,100; C=1,000; D=100; nueva obligación con fecha explícita. |
| F09 | F06: ND aceptada 100 | E=900; C=1,000; D=0; F=100; sin nueva deuda. |
| F10 | NC/ND pendiente, rechazada o incierta | E y deuda sin cambio; documento visible para resolución. |
| F11 | Repetir aceptación NC/ND | Un solo efecto fiscal/financiero y de stock cuando corresponda a NC. |
| F12 | F06: baja válida de NC aceptada, sin devolución | E=1,000; C=1,000; D=0; F=0. |
| F13 | F07: baja válida de NC aceptada después de devolución | E=1,000; C=800; D=200; no borrar devolución ni crear cobro ficticio. |
| F14 | Saldo 100, dos cobros simultáneos de 80 | Solo uno confirma; el otro rechaza sobrepago tras recalcular; D=20. |
| F15 | Saldo 100, cobro 80 concurrente con NC 50 | Si cobra primero: D=0/F=30 tras NC. Si NC primero: cobro 80 rechazado, D=50. Sin saldo perdido. |
| F16 | Saldo 100, cobro 100.01 | Rechazado; no tolerancia de sobrepago. |
| F17 | Cronograma 100 en tres cuotas automáticas | 33.33+33.33+33.34; suma exacta. |
| F18 | Cuota vence hoy, saldo parcial | Parcial, no vencida hasta el día siguiente local. |
| F19 | Reversar los 150 de F02 | C=200; D=800; reapertura de asignaciones originales; historia intacta. |
| F20 | ORG_B usa venta/cuota/request de ORG_A | Acceso rechazado, sin filas o importes de otra empresa. |
| F21 | Venta histórica sin fecha de vencimiento | Saldo visible/cobrable; vencimiento desconocido, no inventado. |
| F22 | Dos monedas o rango vacío | Totales separados por moneda o ceros tipados; ninguna conversión implícita. |
| F23 | Cobro en el límite superior del rango | Pertenece al siguiente período, nunca contado dos veces. |
| F24 | Factura 1,000 a crédito sin abono + GRE | Facturación aceptada 1,000; cobros 0; deuda 1,000; GRE solo conteo. |
| F25 | F06: devoluciones simultáneas de 150 | Una confirma, la segunda rechaza al quedar F=50. |
| F26 | Fallo al persistir cuotas o stock | Venta/abono/cuotas locales revertidos; ningún pago huérfano. |
| F27 | Timeout después de envío SUNAT | Estado incierto y reconciliación; no nueva venta ni duplicación de emisión. |
| F28 | Baja de comprobante sin cancelación comercial | No borra por sí sola la deuda comercial ni devuelve dinero. |

Pruebas futuras obligatorias: dominio monetario, RPC/transacciones con base real, RLS ORG_A/ORG_B, XML/respuestas fiscales, compatibilidad offline y recorridos móviles. Estos casos son especificaciones; no se reportan como pruebas de aplicación ejecutadas.

## 9. Gates y siguiente entrega

**Cierre documental financiero:** reglas, casos y límites definidos en este documento. No equivale a fase 2 implementada.

Antes de crear migraciones: verificar esquema efectivo, escritores, compatibilidad y reconciliación con una lectura del entorno objetivo; cerrar el diseño concreto de tablas/eventos y contratos RPC conforme a estas reglas.

Antes de habilitar crédito/ND: consultar fuentes oficiales SUNAT vigentes, registrar URLs/fecha/versiones y verificar identidad, motivos, forma de pago, vencimientos, XML y procedimientos de baja aplicables. Si la norma exige un comportamiento diferente, actualizar este contrato y sus casos antes de habilitar emisión.

Siguiente entrega: consolidar la evidencia de fase 1 y diseñar la persistencia canónica de fase 2. Mantener bloqueado crédito electrónico hasta completar fase 3. La presente entrega solo modifica documentación; no ejecuta migraciones, emisión ni despliegues.
