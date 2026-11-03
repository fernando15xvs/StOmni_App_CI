# Diseño de persistencia financiera y verificación de navegación

Fecha: 2026-11-02, America/Lima.
Base Git: `45d12acbdcda41b1616e269afc391ab5af58cdc1`.
Referencias: [roadmap 106](106_ROADMAP_MOBILE_HOME_REPORTES_GESTION_SUNAT.md) y [contrato 107](107_CONTRATO_FINANCIERO_CREDITO_CUOTAS_AJUSTES.md).

**Estado:** diseño técnico de fase 2 y revisión estática de fase 1. No hay migraciones ni cambios de aplicación en esta entrega. Consultas a Supabase solo de catálogos/definiciones; no se auditó ni modificó información de clientes.

## 1. Fase 1: evidencia y límite de cierre

| Punto | Evidencia |
|---|---|
| Balance diario | balance_page.dart usa AppTime.startOfToday/endOfToday. |
| Destino | Balance construye ReportesPage con ReportesInitialContext(tab: financiero). |
| Contexto | ReportesInitialContext incluye tab, financialFilter, period, specificDate y customRange. |
| Consumo | ReportesPage.initState aplica índice inicial, fechas, rango, tipo financiero y período. |
| Compatibilidad | Se mantienen dos pestañas; no hay pestaña Facturación todavía. |
| Pruebas existentes | reportes_navigation_contract_test.dart verifica mapeo y prioridad del rango; la prueba de Balance busca textos en archivos. No es un test de interacción. |

No se ejecutó Flutter en esta entrega: flutter/dart no están disponibles en el runtime inspeccionado. El CI 7/7 de la línea base es evidencia previa, no una nueva ejecución.

**Fase 1 permanece parcial.** Para cerrarla añadir/ejecutar prueba de widget con proveedores sustituidos que pulse Histórico financiero, abra Reportes, verifique pestaña y datos filtrados; otra con rango personalizado y filtro de egresos. Verificar también retorno y apertura posterior sin arrastrar estado. Evitar limitarse a búsquedas de texto.

## 2. Inspección efectiva de Supabase

Proyecto consultado: StOmniApp (`iqooedpkihmzkmynsisl`). Resultados observados mediante information_schema.columns, pg_constraint, pg_trigger y pg_proc:

- ventas y pagos_venta usan id bigint; notas_credito usa id uuid.
- Las tres tienen organization_id y UNIQUE(organization_id,id).
- Las relaciones pago→venta y NC→venta/comprobante incluyen organization_id.
- En public no se encontraron tablas con los nombres exactos venta_cuotas ni notas_debito.
- ventas tiene saldo, estado, fue_credito y monto_notas_credito, pero no columna moneda. notas_credito sí tiene moneda. La moneda comercial debe reconciliarse antes de backfill; no inferirla automáticamente de la UI.
- process_sale_v4 y process_sale_with_units_v4 no tienen parámetro de cuotas.
- procesar_pago_deuda_v2 usa request tenant-aware, bloquea sesión de caja antes de venta y recalcula total menos suma de pagos. Permite tolerancia de 0.01 en sobrepago.
- eliminar_pago_venta_v1 ejecuta DELETE de pagos y recalcula total menos pagos; además restringe ventas con comprobante. Debe adaptarse o bloquearse para ventas migradas.
- pagos_venta conserva FK a pagos_deuda_requests y su FK a ventas tiene ON DELETE CASCADE. El nuevo historial debe impedir eliminación en cascada de ventas migradas.
- Triggers activos incluyen enforcement de organización, contexto de caja, permisos/capacidades de venta y controles de notas fiscales. No se observó un trigger de actualización de saldo entre los triggers consultados de esas tres tablas.

No se afirma que se haya inventariado cada función capaz de escribir estas tablas. Antes de activar el motor, completar búsqueda de escritores, grants, políticas y llamadas anidadas; revisar particularmente NC, baja tributaria y anulación.

## 3. Fuente de verdad

Adoptar eventos financieros inmutables por venta, con deltas exactos de exigible y cobros netos. Las cuotas y asignaciones explican la distribución; la proyección resume el resultado.

- Total original se registra una sola vez al iniciar la cuenta.
- Cada pago existente/new se representa una sola vez como evento; no sumar simultáneamente eventos y pagos_venta en el saldo.
- NC/ND efectivas generan deltas de exigible. Una reversión produce evento opuesto, no modifica el evento original.
- Reverso/devolución generan deltas de cobros netos y referencias al origen.
- Proyecciones y ventas.saldo/estado se actualizan en la misma transacción, no con una tarea eventual para autorizar cobros.
- El cliente nunca escribe directamente eventos, proyecciones, cuotas ni asignaciones.

Para una cuenta migrada, E=sum(delta_exigible), C=sum(delta_cobros), D=max(E-C,0), F=max(C-E,0). Estos eventos incorporan la apertura; ventas.total no se suma de nuevo.

## 4. Objetos propuestos

Nombres definitivos para la primera implementación; aún no creados. Todos incluyen organization_id, FK a organizations y clave tenant-aware. Importes numeric(14,2) con límites explícitos, fechas económicas y created_at separados. Importes del transporte nuevo representados como centavos enteros dentro del rango seguro o cadenas decimales validadas.

| Tabla propuesta | Campos principales y responsabilidad |
|---|---|
| venta_cuentas_financieras | PK (organization_id,venta_id); moneda; version_motor; estado_conciliacion; exigible; cobros_netos; saldo_pendiente; excedente; revision. Proyección y punto de identificación de ventas migradas. |
| venta_operaciones_financieras | id uuid; venta_id; tipo; request_id; actor_id; payload_hash; resultado; created_at. UNIQUE(organization_id,tipo,request_id). Solicitud de cobro, devolución, reverso o ajuste. |
| venta_eventos_financieros | id uuid; venta_id; operacion_id; secuencia; tipo; delta_exigible; delta_cobros; efectivo_at; registrado_at; reversa_evento_id; pago_id/nota_credito_id según origen. Historial inmutable. |
| venta_cronogramas | id uuid; venta_id; version; estado; origen_evento_id; creado_por; created_at. Una versión vigente por venta; versiones anteriores conservadas. |
| venta_cuotas | id uuid; venta_id; cronograma_id; numero; obligacion_id uuid estable; vencimiento date nullable solo para legado explícito; importe_original; importe_vigente. Identidad de obligación conservada entre versiones. |
| venta_cuota_movimientos | id uuid; venta_id; cuota_id; evento_id; importe_asignado con signo; tipo; reversa_movimiento_id. Explica pagos, liberación por NC, reversos y reasignaciones de versiones. |

La cuenta financiera contiene estado de conciliación explícito (pendiente, conciliada, bloqueada) y moneda; no se fuerza una cuota ficticia para deuda heredada sin cronograma.

### 4.1 Claves e integridad

- FK (organization_id,venta_id) a ventas(organization_id,id), ON DELETE RESTRICT en cuenta/eventos/cronogramas.
- UNIQUE(organization_id,venta_id,id) en padres que deban ser referenciados desde el mismo expediente; FKs de tres componentes evitan asociar una cuota de otra venta del mismo tenant.
- Referencias pago y NC deben comprobar misma venta y tenant: agregar índices/UNIQUE necesarios en padres o validación equivalente bajo bloqueo; una FK solo por organización no basta.
- Cronograma: UNIQUE(organization_id,venta_id,version); índice único parcial de versión vigente.
- Cuotas: UNIQUE(organization_id,cronograma_id,numero), numero>0; vencimiento no nulo en nuevos contratos; importes no negativos en proyección, importe original positivo.
- Eventos: UNIQUE(organization_id,venta_id,secuencia); deduplicación fiscal por identidad del documento y transición, no por cada intento HTTP.
- Evento origen incluye columnas de referencia tipadas, no un JSON arbitrario como única integridad. ND se agregará con FK cuando exista su tabla; no crear una FK a una tabla inexistente.
- Cobro tiene delta_cobros positivo y delta_exigible cero; ajuste monetario tiene delta_cobros cero; reversión conserva referencia y límite de importe reversible.
- Invariantes agregadas y sumas de cronograma se verifican por función transaccional bajo bloqueo: un CHECK de fila no puede asegurar sumas entre filas.
- Saldo pendiente y excedente no negativos, no simultáneamente positivos; E+F=C+D. Sin cuotas para legado, exponer saldo_sin_cronograma de forma separada.
- Los movimientos históricos de versiones anteriores no se vuelven a sumar al cronograma vigente. Una nueva versión trae transferencia explícita y auditable de asignaciones; nunca duplica cobros.

### 4.2 Índices de acceso

Además de claves únicas: eventos por (organization_id,venta_id,secuencia), cuotas por (organization_id,vencimiento,venta_id), movimientos por (organization_id,cuota_id,evento_id), cuentas por (organization_id,estado_conciliacion). El vencimiento es date; “vencida” se calcula con fecha local y saldo vigente, sin persistir un booleano que quede desactualizado.

## 5. RPC y compatibilidad

| Entrada | Cambio previsto |
|---|---|
| process_sale_v4 / process_sale_with_units_v4 | Mantener firma existente. Agregar entrypoints v5 explícitos con cronograma versionado; compartir núcleo privado para evitar dos motores independientes. No crear sobrecargas ambiguas para PostgREST. |
| v5 de venta | Recibe condiciones de crédito, valida centavos/suma/fechas y persiste venta, pagos, eventos y cuotas atómicamente. Ambos caminos de unidades usan el mismo contrato. |
| procesar_pago_deuda_v2 | Conservar proveedores; para venta migrada delegar al núcleo canónico. Mantener respuesta compatible y rechazar sobrepago real. |
| RPC nuevo de cobro | Recibe request_id y fecha explícita, devuelve moneda, revision, D, F y asignaciones. Comparación estricta de payload incluido fecha para contrato nuevo. |
| eliminar_pago_venta_v1 | Impedir DELETE sobre venta migrada. Clientes nuevos usan reverso autorizado y auditable; no reinterpretar silenciosamente una llamada antigua como devolución de dinero. |
| RPC de reverso/devolución | Operaciones distintas; vínculo al origen, motivo, request_id y método/fecha real cuando corresponda. Autorización y disponibilidad bajo bloqueo. |
| nota_credito_finalizar / tributario_finalizar_proceso | Integrar transición financiera efectiva en la misma transacción que confirma estado; conservar semántica de stock existente. No sumar NC otra vez en la proyección. |
| anular_venta_v2 | Emitir ajuste comercial conforme a 107; proteger historial, fiscalidad y excedentes. Sin borrar venta migrada. |
| consulta de cuenta/cuotas | Lectura por venta validada en tenant; respuesta canónica y conciliación, sin payload fiscal sensible. |

El cliente debe seguir transportando creditTerms por adapter→repository→RPC. Corregir ambos motores de venta y la conversión de cotizaciones. La cola antigua conserva compatibilidad; el nuevo contrato no habilita emisión electrónica offline.

## 6. Orden transaccional

Para toda operación del motor nuevo:

1. Resolver identidad, tenant y permiso; validar formato y payload.
2. Tomar lock idempotente por organización/tipo/request y recuperar respuesta previa si corresponde.
3. Tomar sesión de caja necesaria, siguiendo el orden actual caja→venta; para múltiples sesiones bloquear por ID estable.
4. Bloquear venta y cuenta; para varias ventas usar IDs ordenados (no habilitar compensación entre ventas en esta entrega).
5. Bloquear documento fiscal/orígenes afectados y cronograma cuando corresponda; verificar saldo/revision y transición.
6. Registrar operación, eventos y asignaciones; recalcular cuenta; actualizar compatibilidad de ventas; guardar respuesta.
7. Commit antes de llamar a servicios fiscales externos. Usar trabajo durable y reconciliación para emisión.

**Condición de implementación:** revisar y adaptar caminos de NC/baja que hoy puedan tomar documento antes de venta. No basta cambiar el cobro: todos los participantes deben respetar un orden compatible. En deadlock/serialización, rollback completo y retry acotado con el mismo request_id.

## 7. Seguridad

RLS en todas las tablas expuestas; lectura solo para tenant actual y permiso de ventas/finanzas. Denegar DML directo de anon/authenticated sobre historial y proyecciones. La escritura entra por RPC mínimo autorizado.

Preferir SECURITY INVOKER donde los permisos lo permitan. Si se necesita núcleo privilegiado para escrituras denegadas al cliente, ubicarlo en private con search_path fijo/vacío, validación de auth/tenant y grants mínimos; no usarlo para sortear controles. Wrappers públicos deben validar explícitamente. Revisar default privileges, EXECUTE de PUBLIC y grants efectivos; views de lectura con security_invoker o RPC protegido.

La revisión de diseño no equivale a una auditoría de RLS del proyecto. Pruebas de acceso con rol real, ORG_A/ORG_B, actor sin permiso y acceso directo a tablas son obligatorias.

## 8. Migración en entregas pequeñas

### 2A — Estructuras aditivas y pruebas de aislamiento

Crear cuenta/operaciones/eventos/cronogramas/cuotas/movimientos, índices y permisos en entorno de prueba. Ninguna ruta de producción cambia. Tests de FK cruzada por tenant y por venta, inmutabilidad y restricciones.

### 2B — Reconciliación y apertura del historial

- Inventariar escritores y datos por tenant/moneda; resolver identidad de moneda de ventas.
- Backfill idempotente por origen, sin recrear pagos. Representar venta inicial, pagos y NC efectivas como eventos individuales cuando el historial lo permita.
- Si no puede reconstruirse el pasado, registrar apertura al instante de migración y cobertura histórica desde ese corte; no fabricar secuencia previa ni fechas de pago borradas.
- No duplicar esos orígenes después al activar callbacks. Comparar total, cobros, ajustes, D y F.
- Discrepancias se guardan para conciliación; ninguna corrección destructiva automática.
- Revalidar con escritores controlados/bloqueo al corte; una consulta inicial por sí sola no evita cambios concurrentes.

### 2C — Motor canónico y compatibilidad

Conectar cobros/reversos/NC/bajas/anulación al motor y actualizar lectores de caja/reportes. Una devolución debe reducir ingresos netos o aparecer como egreso separado, nunca ambas cosas a la vez. Ejecutar casos F01–F23/F25–F28 de 107 aplicables, y simular ND hasta fase 4.

### 2D — Contrato de cuotas de venta

Agregar v5 y conectar aplicación; lectura posterior del mismo cronograma; atomicidad de venta/stock/pago, cuotas y unidades; legacy sin vencimientos inventados. Crédito electrónico continúa bloqueado hasta fase 3.

Cada entrega requiere CI y evidencia antes de activar capacidad. Rollback conserva historial; nunca vuelve a total-pagos como autoridad para ventas migradas.

## 9. Qué está verificado y qué falta

**Realizado:** revisión de navegación y tests existentes; consulta de columnas, claves, triggers y dos RPC efectivos de Supabase; confirmación de firmas de venta/NC/baja/anulación; diseño concreto y secuencia de implementación.

**Pendiente:** test de interacción de fase 1; inventario exhaustivo de escritores/permisos; conciliación de datos y moneda; creación y prueba de migraciones; validación fiscal y emisión. No se afirma que los 28 casos de 107 hayan pasado.

**Siguiente cambio de código:** prueba de interacción de navegación y entrega 2A en entorno de prueba, preservando las restricciones actuales de emisión. No generar más documentos de reglas si estos contratos bastan; usar este diseño como base de implementación.

## 10. Ejecución aditiva 2A en desarrollo — 2026-11-02

La estructura de la fase 2A se aplicó en el proyecto de desarrollo `iqooedpkihmzkmynsisl` mediante las migraciones versionadas `20261102212439_financial_2a_additive_tenant_ledger.sql` y `20261102213017_financial_2a_cover_cross_sale_fkeys.sql`.

- Creadas seis tablas: cuentas, operaciones, eventos, cronogramas, cuotas y movimientos de cuotas. Ningún backfill ni cambio en RPC de ventas/cobro.
- Claves foráneas compuestas con organización y venta, índices, una versión de cronograma vigente por venta, restricciones monetarias, `request_id` único por organización/tipo y triggers de historial inmutable.
- Se mantuvieron RLS y lectura únicamente de tenant autorizado con permiso `tenant.read`; `anon` sin lectura y `authenticated` sin escrituras directas.
- Test pgTAP añadido: `supabase/tests/database/financial_2a_tenant_ledger_contract_test.sql`, con 27 aserciones estructurales y transaccionales que se revierten tras ejecutarse.
- Inspección en la base desplegada: seis tablas con RLS activo y una política SELECT por tabla. El asesor de rendimiento no reporta ya FKs sin índice para estas tablas después de la segunda migración.
- La validación definitiva de ambas migraciones terminó 7/7 en GitHub Actions, ejecución 41529616806, commit CI 821347d; la fase 2A está validada.

**Límites actuales:** fases 2B–2D pendientes. Estos objetos no son todavía la fuente de verdad de deudas, pagos ni facturación SUNAT. No habilitar crédito electrónico ni notas de débito a partir de esta migración.

## 11. Fase 2B, bloque inicial: preconciliación segura — 2026-11-02

**Estado:** preanálisis en desarrollo implementado, apertura de historial no iniciada. No marcar 2B como cerrada antes de pruebas CI y reconciliación transaccional del corte.

- Migración: `20261102215345_financial_2b_legacy_reconciliation_preview.sql`. Función administrativa `private.financial_2b_preview_sales(organization_id uuid, limit integer)`, `SECURITY INVOKER`, lectura solamente. Sin permisos de ejecución para `PUBLIC`, `anon`, `authenticated` ni `service_role`; se consulta mediante una sesión de administración de la base.
- Calcula por venta importes exactos de venta, suma de pagos y saldo estimado. Clasifica como `lista` solo sin discrepancias; `bloqueada` con motivos tipados (saldo incorrecto, falta de fecha de cobro, fracciones de centavo, sobrepago, notas de crédito, documento en otra moneda, venta anulada y cuenta ya abierta).
- De forma conservadora **bloquea toda venta con notas de crédito** para no dar por aceptada una nota pendiente/baja; ello se refinará con historia tributaria efectiva al completar 2B. No presupone que `ventas.monto_notas_credito` sea historia exhaustiva.
- Moneda: se verifica el código configurado de la organización y se contrasta contra cada comprobante; la inexistencia de comprobante no implica que la moneda de la operación haya sido probada históricamente. Requiere revisión de acuerdos/monedas heredadas antes de abrir eventos.
- Prueba pgTAP: `financial_2b_reconciliation_preview_contract_test.sql`, con 15 aserciones y fixtures reversibles. No activa el motor nuevo ni modifica balances heredados.
- Datos inspeccionados en Supabase de desarrollo: 2 organizaciones (PEN), 0 ventas, 0 pagos de venta, 0 NC, 0 cuentas y 0 eventos. No existe historial real al que aplicar backfill. Se probará la apertura con datos sintéticos de manera transaccional y sin invención de fechas.

**Escritores encontrados inicialmente (no todos auditados):** `process_sale_v3` (núcleo bajo v4), `process_sale_v4`, `process_sale_with_units_v4`, `procesar_pago_deuda_v2`, `eliminar_pago_venta_v1`, `nota_credito_finalizar`, `tributario_finalizar_proceso`, `anular_venta_v2`. Investigar también reintentos, reversos, colas offline, stock y funciones anidadas.

**Para cerrar 2B:** diseñar y probar corte transaccional con escritores controlados, eventos de venta/pago/NC idempotentes por origen, trazabilidad de ventanas sin historia y persistencia auditable de discrepancias. Evitar escribir en `venta_cuentas_financieras` mientras las RPC actuales puedan mutar ventas sin emitir eventos canónicos. `ventas.saldo` sigue siendo compatibilidad legacy, no el nuevo motor autoritativo.

## 12. Fase 2B: apertura controlada y protección legacy — 2026-11-02

El primer bloque de 2B (preconciliación) fue validado con **CI 7/7**, ejecución `41532953472`. La continuación incluye:

- Migración `20261102225452_financial_2b_guarded_legacy_opening.sql`: `private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)` es una entrada **administrativa, SECURITY INVOKER** sin EXECUTE de `PUBLIC`, `anon`, `authenticated` ni `service_role`. No es un RPC público de cliente.
- Para un corte de mantenimiento confirmado, bloquea escrituras en ventas, pagos, notas de crédito y comprobantes mientras valida saldo, moneda, fechas de pagos y estado de la venta. Rechaza cualquier discrepancia, NC que exija conciliación, moneda distinta o venta fuera de la ventana de diagnóstico.
- Crea `venta_cuentas_financieras` con estado **pendiente**, registra operación de apertura con un resumen del corte y conserva un evento de venta más uno por cada pago confirmado y rastreable. Las fechas de los eventos proceden de fuentes registradas, no de vencimientos inventados.
- Identifica cobertura histórica como `fuentes_actuales_no_historial_exhaustivo`: pagos eliminados, ajustes ausentes o estados fiscales antiguos no pueden reconstruirse con certeza. No afirmar balance histórico definitivo.
- Repetir la apertura con el mismo `request_id` devuelve el resultado existente; otra solicitud para la misma cuenta es rechazada. Los eventos deben cuadrar exactamente con el corte o se aborta toda la transacción.
- Triggers `zz_fin2b_legacy_*_guard`: bloquean UPDATE/DELETE de la venta abierta, así como INSERT/UPDATE/DELETE sobre sus pagos y notas de crédito. Se ejecutan mediante un núcleo privado SECURITY DEFINER con `search_path` fijo y sin EXECUTE directo concedido. La reparación del tipo heterogéneo de identificador se registra en `20261102225605_financial_2b_guard_legacy_row_identity.sql`. **Estas guardas son temporales**: la fase 2C deberá sustituirlas por operaciones canónicas auditables antes de liberar cobros para cuentas abiertas.
- Nueva prueba `financial_2b_guarded_legacy_opening_contract_test.sql`: 22 comprobaciones de seguridad, apertura, bloqueo, idempotencia y reconstrucción de eventos, con fixtures revertidos por ROLLBACK; se ejecutó en Supabase de desarrollo sin errores SQL. Validado en CI 7/7, ejecución 41541848185, commit CI d620df3. El backend, la reconstrucción, las pruebas multiempresa y las compilaciones terminaron correctamente.
- La base de desarrollo seguía sin ventas, pagos, notas de crédito ni cuentas reales al comenzar este bloque. Ninguna apertura real ni migración masiva se ha ejecutado.

**Condición de operación:** no habilitar aperturas masivas mientras no se auditen todos los escritores, su orden de locks y la evidencia de cobertura temporal. La función es administrativa e intencionadamente conservadora; el motor de saldo canónico y los lectores del cliente permanecen sin activar.

## 13. Fase 2C1 — Auditoría canónica y preflight estricto (sin escrituras)

**Estado a 2026-11-02:** funciones instaladas en Supabase de desarrollo y 26 pruebas pgTAP incorporadas; CI completo 7/7 aprobado, ejecución 41545752782 (commit CI e2d7f0a).

Migraciones:
- `20261102232401_financial_2c_strict_ledger_audit_and_payment_preflight.sql`.
- `20261102232505_financial_2c_preflight_null_and_payment_source_guard.sql` (corrige organización nula y verifica importe por cada origen de pago).

Funciones internas (ambas `SECURITY INVOKER`, `STABLE`, `search_path` vacío, revocadas a `PUBLIC`, `anon`, `authenticated` y `service_role`):
- `private.financial_2c_audit_sale(uuid,bigint)`: reconstruye el exigible, cobros, deuda y excedentes a partir de los eventos y verifica la proyección, la secuencia, cobertura histórica certificada, pagos originales vinculados por identidad e importe, saldo legacy y presencia de NC. Devuelve bloqueos expresos; no marca automáticamente como conciliada una cuenta.
- `private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)`: **simulación sin escrituras**. Exige moneda, fecha, método y monto decimal positivo exacto (dos decimales, tolerancia cero), rechazando hasta un sobrepago de S/ 0.01. Bloquea cuentas pendientes/no auditadas, request existente, efectivo sin integración de caja y discrepancias de fuentes.

La etiqueta `historico_auditado` solo se usa en fixtures sintéticos para probar la ruta de éxito; **ninguna ruta desplegada certifica automáticamente el pasado**. Las aperturas 2B actuales siguen identificadas con `fuentes_actuales_no_historial_exhaustivo`, por lo que no quedan habilitadas para registrar pagos.

Pruebas: `supabase/tests/database/financial_2c_strict_ledger_preflight_contract_test.sql`, 26 aserciones con dos organizaciones ficticias, montos exactos, moneda, cobertura, sobrepago de 0.01, identidad de pago y bloqueos. Transacciones de prueba terminan en `ROLLBACK`.

**No modificar todavía `procesar_pago_deuda_v2`, `eliminar_pago_venta_v1`, notas de crédito ni la interfaz.** El primer escritor transaccional 2C2 necesita resolver caja→venta, autorización, request_id, bloqueo de guardas legacy, asignación de cuotas y atomicidad de saldo, eventos y proyecciones.

**Evidencia de cierre 2C1:** 2026-11-02, GitHub Actions 41545752782: backend, Flutter/Android, Windows, Linux, macOS/iOS, gates estáticos y resumen CI con SUCCESS. Los 26 casos pgTAP se ejecutaron sobre la reconstrucción limpia. Pendientes 2C2/2C3: primer escritor transaccional, permisos/caja y rutas de NC/reversos; el preflight no crea cobros ni autoriza operaciones financieras por sí solo.

## 14. Fase 2C2 — Primer cobro atómico por transferencia (solo interno)

**Estado:** implementado en el proyecto Supabase de desarrollo, sin apertura a clientes ni escritura de caja; **CI completo 7/7 aprobado**, ejecución 41549196404, SHA CI 70c2a03 (2026-11-02, hora Lima). Cuentas de ventas reales 0, por lo que las pruebas usan únicamente dos empresas y ventas sintéticas con ROLLBACK. La etiqueta `historico_auditado` fue asignada solo a fixtures del test, nunca a datos heredados reales.

Migraciones:
- `20261102234949_financial_2c2_private_intents_and_guard.sql`: añade `resultado_payload` a la operación financiera y crea `private.financial_2c2_write_intents`. La intención incluye organización, venta, operación, UUID de solicitud, monto exacto, fecha, saldo esperado, etapa y `pg_current_xact_id()` (tipo `xid8`). Su RLS y revocaciones impiden que `anon`, `authenticated` o `service_role` creen permisos de escritura. La función privada de guardas 2B solo acepta una inserción del pago y la actualización exacta del saldo vinculadas a una intención de la misma transacción; cualquier escritura de los RPC legacy sigue bloqueada para cuentas abiertas.
- `20261102235031_financial_2c2_private_atomic_transfer_writer.sql`: función `private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)`. `SECURITY INVOKER`, sin concesiones EXECUTE a roles de cliente, ni `service_role`. Solo transferencias no efectivas; no registra cobros de caja ni asigna cuotas. Bloquea la cuenta y la venta, verifica fecha, importe exacto y conciliación histórica auditada; escribe en una transacción operación `cobro`, `pagos_venta`, evento asociado al pago, saldo financiero y saldo legacy, verifica la auditoría canónica al final y elimina la intención de la transacción. Si falla cualquier etapa, PostgreSQL revierte toda la llamada.
- `20261102235321_financial_2c2_utc_idempotency_fingerprint.sql`: fija `TimeZone=UTC` dentro de la función para calcular la huella SHA-256 igual desde distintas zonas de sesión; la idempotencia se identifica por `(organization_id,tipo,request_id)` y rechaza reintentos con carga diferente. `pagos_venta.request_id` permanece NULL en esta ruta porque la FK de ese campo pertenece a `pagos_deuda_requests` legacy; la cadena canónica es `operacion -> evento -> pago_id`. El resultado y su pago se almacenan en `resultado_payload`.

Pruebas: `supabase/tests/database/financial_2c2_atomic_transfer_writer_contract_test.sql`, 33 aserciones pgTAP. Cubren abonos de S/ 40 y S/ 60 sobre venta S/ 100, saldo cero exacto, sobrepago S/ 0.01 rechazado, importes no centesimales, moneda, fechas, idempotencia con cambio UTC/Lima, aislamiento de empresas, protección de registros originales, intento de falsificar una variable GUC y ausencia de permisos client/service, de registros de caja y de intenciones persistentes. Ejecutadas en desarrollo con fixtures revertidos; validado CI 7/7 sobre reconstrucción limpia, copia/restore y pruebas multiempresa (41549196404).

**Límites de seguridad:** no sustituir `procesar_pago_deuda_v2` ni `eliminar_pago_venta_v1` todavía. Las guardas 2B siguen siendo el cortafuegos de escrituras de cuentas abiertas; 2C2 solo permite exactamente una transferencia administrativa a través de una intención privada para la transacción actual. Nunca certificar el pasado automáticamente para habilitar la función en ventas legacy. Antes de una integración cliente deben cerrarse permisos de empleados, caja, notas de crédito, reversiones, cuotas y pruebas de concurrencia real.

**Evidencia de cierre del primer bloque 2C2:** ejecución GitHub Actions `41549196404`, 7/7 `SUCCESS`. Esta validación cubre únicamente el escritor administrativo de transferencias sin caja, no la habilitación de pagos de clientes, cuotas, reversos ni NC.

## 15. Fase 2C3A — permiso de cobro y preflight de caja

**Estado:** aplicado en Supabase de desarrollo y validado en GitHub Actions **7/7 SUCCESS**, ejecución `41554190691` (SHA CI `c7608e2`), con 26 pruebas pgTAP reversibles.

Migración: `20261103003110_financial_2c3_cash_authorization_preflight.sql`.

- Registra `sales.collect` en `permissions` sin otorgarlo automáticamente a operadores. El administrador activo conserva el permiso mediante el modelo RBAC existente; un empleado operador lo requiere vía rol activo con `role_permissions` u override explícito `employee_permission_overrides`. Un override `false` niega el permiso de un operador.
- `private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)`: `STABLE`, `SECURITY INVOKER`, `search_path` vacío. Comprueba cuenta conciliada, cobertura histórica certificada, PEN, importe con centavos exactos, saldo disponible, request no reutilizado, fecha real de venta y cobro, sesión de caja abierta perteneciente al actor dentro de la misma organización, caja/sucursal activa, empleado activo en esa sucursal y `sales.collect` efectivo. Si existe contexto JWT, exige que `auth.uid()` coincida con el actor.
- La función es **solo de preanálisis** y devuelve `preflight_efectivo_aprobado_sin_registro` sin insertar `pagos_venta`, eventos, operaciones ni movimientos de caja. `EXECUTE` está revocado a `PUBLIC`, `anon`, `authenticated` y `service_role`. El `p_actor_id` explícito es para invocación administrativa interna; nunca se debe aceptar como prueba de identidad desde el cliente. La futura API 2C3B deberá derivarlo exclusivamente de `auth.uid()` validado y aplicar locks `FOR UPDATE` sobre cuenta y sesión dentro del mismo cobro.
- Test `supabase/tests/database/financial_2c3_cash_permission_preflight_contract_test.sql`: 26 aserciones con empresas, usuarios, sucursales, empleados y cajas sintéticos, usando ROLLBACK. Demuestra default-deny, concesión expresa, admin activo, denegación expresa, usuario/caja de otro tenant, caja cerrada o inactiva, empleado inactivo, fecha errónea, importe inválido/sobrepago y ausencia de escrituras.
- El sistema de suscripción protege las cajas aun en entornos de prueba; las simulaciones de activación/inactivación de las cajas se efectúan solo en fixtures reversibles con `SET LOCAL session_replication_role=replica` fuera de PL/pgSQL. No se relajó la lógica de suscripciones existente.
- Validación post-deploy: tablas de ventas, pagos, cuentas, eventos, sesiones e intenciones en cero; sin nuevos avisos de seguridad específicos para `financial_2c3`.

**Próximo bloque 2C3B:** extender el escritor canónico con efectivo solamente tras incorporar `sales.collect`, identidad real y sesión abierta bloqueada, caja/sucursal exactas, guardia de escritura basada en intención privada por transacción, ledger+venta y reversión integral ante cambios de sesión. En paralelo, completar pagos por cuota y notas de crédito antes de habilitar rutas cliente. No modificar todavía `procesar_pago_deuda_v2` ni su UI.

**Evidencia CI 2C3A:** T04 pgTAP, esquema sin drift, aislamiento por tenant, prueba de concurrencia, restauración y compilaciones Android, Windows, Linux y macOS/iOS superadas el 2 de noviembre de 2026 (hora Lima). Todavía no se concede EXECUTE a clientes ni se registran pagos en efectivo.

## 16. Fase 2C3B — primer escritor atómico de efectivo (interno)

**Estado al 2026-11-02, hora Lima:** instalado y probado en Supabase DEV; **GitHub Actions 7/7 SUCCESS** (ejecución 41560080380, SHA CI f9e19e0, 28 aserciones pgTAP).

Migraciones:
- `20261103012411_financial_2c3b_cash_intent_and_guard.sql`: extiende las intenciones privadas del flujo 2C2 con `actor_id`, `cash_session_id` y `cash_register_id`. La restricción impide contexto de caja en transferencias y exige identidad, sesión y caja para efectivo. La guarda `financial_2b_guard_legacy_financial_write()` solo permite insertar un pago en efectivo cuyo método, importe, fecha, JWT, caja y sesión coincidan con la intención del mismo `pg_current_xact_id()`, y únicamente para sesiones abiertas de la empresa. Conserva las reglas de transferencia, actualizaciones de saldo y bloqueo de mutaciones legacy.
- `20261103012554_financial_2c3b_atomic_cash_writer.sql`: `private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)`, con `SECURITY INVOKER`, `search_path` fijo, `TimeZone=UTC` y EXECUTE revocado a `PUBLIC`, `anon`, `authenticated` y `service_role`. Deriva el actor de `auth.uid()` y exige membresía activa mediante `private.current_organization_id()`; no recibe identidades del cliente por parámetro. Bloquea cuenta y venta `FOR UPDATE`, sesión `FOR UPDATE` y caja `FOR SHARE`; ejecuta el preflight 2C3A después de los locks. Una solicitud idempotente debe coincidir con organización, venta, actor, sesión, importe, moneda, método y fecha o se rechaza.
- La misma función genera operación con actor, registra `pagos_venta` asociado a sesión y caja real, confirma los valores finales después del trigger de caja, añade evento de cobro, actualiza saldos y revisión, sincroniza venta legacy y ejecuta auditoría canónica antes del commit; limpia la intención privada. Toda excepción aborta la transacción completa.
- `supabase/tests/database/financial_2c3b_atomic_cash_writer_contract_test.sql`: 28 aserciones con fixtures ROLLBACK: S/40 + S/60 sobre venta S/100, reintentos idénticos entre Lima y UTC, rechazo de cambio de payload/sesión, sobrepago de un centavo, fracciones de centavo, falta de JWT, operador sin permiso, sesión cerrada, otro tenant, bloqueo legacy, saldo final y vínculo caja–pago. Las cuentas de prueba solo usan `historico_auditado` artificial en fixtures; **ninguna cuenta real ha sido certificada automáticamente**.

**Condiciones pendientes para habilitar en producto:** revisión de integración del RPC público con permisos y claims verificados, reglas de cierre y conciliación de caja, cuotas, reversos, notas de crédito, pruebas de concurrencia de cobro efectivo/cierre de sesión, y compatibilidad de reportes. Se mantienen las rutas de cobros legacy para cuentas aún no abiertas en ledger; los escritores legacy para cuentas abiertas siguen bloqueados. No se activa UI ni se concede permiso de ejecución a clientes por esta migración.

**Evidencia de cierre del bloque interno 2C3B:** ejecución `41560080380` (primer intento, `SUCCESS`). Contratos pgTAP, aislamiento multiempresa, concurrencia, segunda reconstrucción del esquema, restauración, Android, Windows, Linux y macOS/iOS aprobados. Esta evidencia NO activa API de cliente, cuotas ni reversos; los escritores internos siguen sin EXECUTE para clientes o service_role.

## 17. Fase 2C4 — Aplicación canónica de cobros a cuotas

**Estado:** implementado y comprobado en Supabase DEV (45 pruebas pgTAP reversibles, 31 por transferencia y 14 por efectivo) y **GitHub Actions 7/7 SUCCESS** (ejecución 41562326227, SHA CI 3344e3f). No se expone API al cliente.

Migraciones:
- `20261103014404_financial_2c4_atomic_installment_allocation.sql`: índice único parcial por organización/venta/cuota/evento para asignaciones `cobro`; trigger `zz_fin2c4_allocate_receipt_to_installments` AFTER INSERT de un evento `cobro` para distribuir el importe, sin volver a crear pagos ni modificar la suma ingresada. La función privada `financial_2c4_allocate_cash_receipt()` comprueba que el evento provenga de la intención privada de la transacción (`operation_id`), bloquea cronograma vigente v1 y cuenta, verifica numeración consecutiva y que `SUM(importe_vigente)-SUM(asignado)` coincida exactamente con el saldo anterior al cobro. Ordena por vencimiento ascendente y número de cuota; almacena movimientos positivos inmutables y exige suma de asignaciones igual al pago al centavo. Si falla, aborta el cobro completo.
- `20261103014645_financial_2c4_correct_private_intent_operation_column.sql`: corrección de mapeo entre `private.financial_2c2_write_intents.operation_id` y `public.venta_eventos_financieros.operacion_id`, descubierta durante primera prueba; corregida antes de la validación. No hubo movimientos persistentes del intento rechazado.
- `private.financial_2c4_installments(uuid,bigint,date)`: lectura interna estable/invocadora de pagos asignados, pendiente por cuota, estado (`pendiente`, `parcial`, `pagada`) y vencimiento en fecha local America/Lima. Una cuota que vence hoy no está vencida; sí al día siguiente si queda saldo. Sin filas si no existe cronograma: el legado conserva saldo canónico sin vencimientos inventados.
- `supabase/tests/database/financial_2c4_atomic_installment_allocation_contract_test.sql`: 31 aserciones, incluyendo cronograma S/100 dividido en S/33.33 + S/33.33 + S/33.34, pagos S/50 + S/30 + S/20, dos vencimientos iguales desempatados por número, reintento sin duplicación, cronograma inconsistente rechazado y cuenta histórica sin cuotas.
- `supabase/tests/database/financial_2c4_cash_installment_integration_test.sql`: 14 aserciones, caja real del fixture más pagos S/40 + S/60, dos cuotas S/50, vínculo con sesión de efectivo, dos cobros sin doble ingreso, y estados finales conciliados.

**Alcance / gate estricto:** se asigna exclusivamente a cronogramas nuevos **v1** completos, no legados, sin NC ni reversos previos. Para venta sin cronograma no se fuerza uno. Cronograma sustituido/v2 se bloquea hasta implementar transferencia explícita de asignaciones entre versiones, sin sumar dos veces pagos históricos. No implementa creación fiscal de venta a crédito v5, edición de cuotas, notas de crédito, reversos o liquidación cliente. Los escritores financieros y la lectura interna permanecen con EXECUTE revocado a PUBLIC, anon, authenticated y service_role.

**Próximo bloque:** reversos y notas de crédito auditables (eventos compensatorios sin borrar pagos originales), junto con la versión contractual de creación de ventas/cuotas y pruebas de concurrencia de todos los escritores antes de activación de UI.

**Evidencia de cierre del bloque interno 2C4:** GitHub Actions `41562326227`, primer intento 7/7 `SUCCESS` con reconstrucciones limpias, pgTAP, aislamiento multiempresa, prueba de concurrencia general, restauración y compilaciones Flutter/Android/Windows/Linux/macOS-iOS. No equivale a validación de concurrencia específica de cierres de caja/NC/versionado de cuotas ni habilita UI o API pública.

## 18. Fase 2C5A — Reverso íntegro y auditable de transferencia

**Estado:** instalado en Supabase DEV y validado en GitHub Actions **7/7 SUCCESS** (ejecución `41568646642`, SHA CI `a2004a8`) con 43 aserciones pgTAP reversibles (29 de reverso completo de transferencia y 14 de frontera efectivo).

**Alcance deliberadamente limitado:** un reverso contable corrige un **cobro de transferencia no válido** y NO constituye devolución ni salida de caja. El dinero en efectivo recibido exige otro registro de egreso verificado, permisos y conciliación de sesión. Tampoco se permiten reversos parciales en 2C5A.

Migraciones:
- `20261103024455_financial_2c5a_reversal_guard_and_net_audit.sql`: amplía la intención privada por transacción con medio `reverso_transferencia` sin contexto de caja, mantiene las guardas de transferencias y efectivo y autoriza actualización de proyección legacy únicamente cuando exista un evento compensatorio negativo que referencie el mismo pago/venta y el cobro original válido. Crea índices únicos para que un evento original tenga máximo un reverso completo y una asignación de cuota máximo un movimiento de reverso. Adapta `private.financial_2c_audit_sale`: conserva los pagos originales brutos y exige que `SUM(pagos_venta.monto)+SUM(eventos_reverso.delta_cobros)=cobros_netos`, validando enlace con origen, método transferencia, monto total, signo y tenant. No borra pagos históricos.
- `20261103024625_financial_2c5a_atomic_full_transfer_reversal.sql`: función interna `private.financial_2c5a_reverse_transfer_payment(uuid,bigint,uuid,uuid,timestamptz)`. `SECURITY INVOKER`, `TimeZone=UTC`, `search_path` vacío, sin EXECUTE para `anon`, `authenticated` ni `service_role`. Idempotencia por `organization_id/tipo=reverso/request_id` y huella SHA-256 de organización, venta, origen y fecha. Bloquea cuenta/venta y evento original; acepta solo cobro de transferencia aplicado, original único, fecha no anterior al cobro y no futura; añade operación, evento `reverso` de delta_cobros negativo, misma referencia `pago_id` y FK `reversa_evento_id`; reabre las mismas cuotas mediante movimientos negativos con `reversa_movimiento_id`. Proyecta saldo/revisión y comprueba auditoría canónica y agregado de cuotas antes de commit. Cualquier fallo revierte todo.
- `supabase/tests/database/financial_2c5a_full_transfer_reversal_contract_test.sql`: 29 aserciones. Cobros 50+30+20 sobre venta 100 en tres cuotas; después de liquidarla se revierte únicamente el cobro intermedio 30 y se reabren 16.66 de la cuota 2 y 13.34 de la cuota 3. Un cobro nuevo de 30 salda de nuevo sin borrar pagos ni duplicar el historial. Verifica reintentos UTC/Lima, empresa ajena, fechas, unicidad de reverso, protección de las asignaciones y RLS/permisos.
- `supabase/tests/database/financial_2c5a_cash_reversal_guard_contract_test.sql`: 14 aserciones. Rechaza el reverso de un cobro en efectivo, conserva su sesión y pago, permite revertir una transferencia adicional en la misma venta y confirma que el cobro de caja original no se anula ni se contabiliza dos veces.

**Límites/etapas siguientes:** la reducción de `cobros_netos` de 2C5A es una **corrección contable de transferencia**, no un egreso físico; no generar movimientos de caja de salida. No se habilita a clientes ni se modifica `eliminar_pago_venta_v1`. Restan: un contrato de devoluciones de excedentes con salida real de fondos, reversos de efectivo con conciliación de caja, notas de crédito y ajustes, cronogramas versionados, cuota v5 y pruebas de concurrencia específicas y de reportes. Los datos heredados nunca se marcan `historico_auditado` por esta migración.

**Evidencia de cierre 2C5A:** CI `41568646642` en primer intento, 7/7 `SUCCESS`, incluyendo pgTAP (43 casos adicionales), aislamiento multiempresa, pruebas generales de concurrencia, restauración, segunda reconstrucción sin drift y compilaciones Android, Windows, Linux y macOS/iOS. Los procedimientos siguen restringidos y no implementan movimiento de caja ni devolución real de dinero. Las pruebas de concurrencia específicas de reversos contra NC, cierres de caja y transferencias simultáneas permanecen como gate futuro.

## 19. Fase 2C5B-A — Expediente de devolución sin desembolso

**Estado:** aplicado en Supabase DEV y validado GitHub Actions **7/7 SUCCESS** (ejecución `41572511318`, SHA CI `04f5e09`, 23 aserciones pgTAP reversibles).

**Hallazgo:** los escritores canónicos impiden sobrepagos y todavía no existe integración entre NC aceptadas, reducción del exigible y excedentes certificados. No es seguro afirmar una devolución monetaria basándose únicamente en una NC.

**Migración:** `20261103032308_financial_2c5b_internal_refund_case_intake.sql`.

- Tabla privada `private.venta_solicitudes_devolucion` con FK compuesta tenant-venta-cuenta, FK compuesta a NC de esa venta, request UUID único por empresa e índice único por NC para impedir solicitudes paralelas. Importes positivos PEN exactos, actor JWT, motivo de 10 a 500 caracteres, huella SHA-256, estado único `pendiente_conciliacion`. Registro inmutable (trigger bloquea UPDATE y DELETE), RLS activa, sin permisos de escritura/lectura para clientes ni service_role.
- Escritor `private.financial_2c5b_open_refund_case(uuid,bigint,uuid,uuid,numeric,text)`: SECURITY INVOKER, UTC, search_path vacío, EXECUTE privado. Identidad derivada de `auth.uid()`; `private.current_organization_id()` activa y `tenant.admin`. Bloquea cuenta `FOR UPDATE`; exige cuenta conciliada PEN y NC con `estado=aceptado`, `aceptado_at`, `afecta_dinero=true`, moneda PEN y no dada de baja. Rechaza importes superiores al valor NC o cobros netos, reintentos con contenido diferente y solicitudes duplicadas para la misma NC.
- Devuelve explícitamente `dinero_entregado=false` y `excedente_reservado=false`. **No** genera evento de devolución, salida de caja, transferencia bancaria, actualización de saldo ni nueva obligación. El estado del expediente **no implica** derecho certificado al reembolso ni orden de pago aprobada.
- `supabase/tests/database/financial_2c5b_internal_refund_case_contract_test.sql`: 23 aserciones con NC/empresa/ventas ficticias y ROLLBACK; rechazo de operación sin JWT, operador, admin ajeno, NC no aceptada, monto incompatible, fracciones de centavo y request reusado. Comprueba ausencia de efectos monetarios adicionales comparando movimientos antes/después, preservando el movimiento legítimo del cobro de prueba.

**Gate de liquidación 2C5B-B:** primero integrar las NC fiscalmente aceptadas al ledger y a las cuotas, conciliar excedente y reservas bajo bloqueo; después diseñar egreso bancario/caja con autorización, evidencia real, saldo de fondos, sesión/empresa correctas, reversión compensatoria y pruebas concurrentes. Ningún RPC de devolución o UI para usuarios permanece habilitado.

**Evidencia CI 2C5B-A:** `41572511318` (primer intento, 7/7 SUCCESS), con pgTAP, RLS/grants, aislamiento multiempresa, reconstrucción y restauración de PostgreSQL, Android, Windows, Linux y macOS/iOS. El flujo crea solamente expedientes privados pendientes; NO liquida fondos, NO genera excedentes y NO registra devoluciones en caja ni banco.
