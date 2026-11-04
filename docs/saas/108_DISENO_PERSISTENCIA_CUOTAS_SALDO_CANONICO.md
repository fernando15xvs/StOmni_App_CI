# Diseño de persistencia financiera y verificación de navegación

Fecha: 2026-11-02, America/Lima.
Base Git: `45d12acbdcda41b1616e269afc391ab5af58cdc1`.
Referencias: [roadmap 106](106_ROADMAP_MOBILE_HOME_REPORTES_GESTION_SUNAT.md) y [contrato 107](107_CONTRATO_FINANCIERO_CREDITO_CUOTAS_AJUSTES.md).

**Estado vigente (2026-11-03, America/Lima):** implementados y verificados en CI 7/7 y Supabase DEV los bloques financieros 2A, 2B, 2C1–2C6B y 2C5B-B. La última migración registrada es `20261104010306_financial_2c5b_refund_settlement.sql`, con 49/49 pruebas reversibles ejecutadas en DEV. El diseño y las observaciones de las secciones 1–10 son una fotografía histórica del 2026-11-02, anterior a esas implementaciones; la evidencia de cierre real se encuentra en las secciones posteriores. **Aún no hay habilitación de UI de devoluciones, integración bancaria ni GO a producción.** Próxima dependencia: venta a crédito v5 con cuotas persistidas.

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

## 20. Fase 2C6A — Preanálisis privado de la primera NC monetaria

**Estado:** implementado en Supabase DEV; 32 aserciones pgTAP reversibles aprobadas antes y después de instalar. **CI completo 7/7 SUCCESS**, ejecución [41576975707](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41576975707), primer intento. Source validado `1100b7b6be5911b7736750c95f3782f8531767ef`; espejo `675a48eda6699cfa10f19bef6c1886fbec75897e`.

- Migración `20261103041349_financial_2c6a_credit_note_preview.sql`; versión tomada del historial efectivo de Supabase después de generar el archivo con CLI.
- `private.financial_2c6a_preview_credit_note(uuid,bigint,uuid)`: STABLE, SECURITY INVOKER, search_path vacío, UTC, sin EXECUTE para PUBLIC/anon/authenticated/service_role. Exige JWT, empresa activa y tenant.admin.
- Simula exclusivamente la primera NC monetaria aceptada PEN sin baja, con fecha válida y monto que no exceda el exigible. Audita cobertura histórica, eventos, pagos y proyección; no cambia el auditor compartido, que continúa bloqueando cobros con NC.
- Calcula exigible, deuda y excedente propuestos sin modificar cobros ni venta original. En cronograma v1 reduce pendientes por vencimiento y número descendentes; revisa todas las cuotas, incluso las pagadas. Sin cronograma conserva el saldo sin inventar fechas.
- Bloquea múltiples NC aceptadas, ajustes anteriores, falta de conciliación, historial no certificado, moneda distinta, cuota inconsistente o versiones no soportadas.
- Resultado explícito: simulacion_sin_escrituras, aplicado=false, autoriza_escritura=false, excedente_reservado=false, dinero_entregado=false. Es una instantánea sin locks; nunca usarla como autorización reutilizable para pagar o escribir.
- Test `financial_2c6a_credit_note_preview_contract_test.sql`: 32 aserciones, ORG_A/ORG_B, saldo 60 → 40 con NC20, empate de vencimientos, centavos, NC70 sobre deuda60 → excedente10, venta pagada → excedente20, permisos y rechazos. Fixtures terminan en ROLLBACK; no se certifica historia real.
- Asesor de seguridad sin hallazgos nuevos sobre esta función; persisten avisos anteriores del proyecto, fuera de este cambio.

**Siguiente bloque 2C6B:** implementar aplicación atómica de NC al ledger y reclasificaciones de cuotas, con identidad del origen fiscal, deduplicación de aceptación, orden de locks compatible entre cobro/NC/baja, compensación por baja y pruebas concurrentes específicas. Revalidar todos los datos dentro de la transacción. Solo después resolver reservas y desembolsos 2C5B-B. No abrir UI ni RPC cliente con este preanálisis.

**Evidencia de cierre 2C6A:** 60 archivos pgTAP / 1.250 aserciones aprobadas en dos reconstrucciones, incluida la nueva suite de 32 casos; sin drift, restauración, aislamiento multiempresa, concurrencia general, gates estáticos, Android, Windows, Linux y macOS/iOS aprobados. La concurrencia específica NC/cobro/baja corresponde al futuro escritor 2C6B, no a esta función de lectura. Supabase DEV permanece sin ventas/NC/cuentas/solicitudes reales después de ROLLBACK de fixtures. Los commits posteriores a este candidato solo registran esta evidencia documental.

## 21. Inicio 2C6B — incompatibilidades transaccionales comprobadas

Revisión del 2026-11-03 (America/Lima), mediante pg_get_functiondef y privilegios efectivos de Supabase DEV. **2C6B sigue pendiente de implementación; esta entrega es diagnóstico, no aplicación de NC ni validación concurrente.**

| Entrada inspeccionada | Orden observado / efecto relevante |
|---|---|
| financial_2c2_record_transfer_payment | request advisory → cuenta FOR UPDATE → venta FOR UPDATE |
| financial_2c3b_record_cash_payment | request advisory → cuenta → venta → sesión de caja → caja FOR SHARE |
| nota_credito_finalizar | NC FOR UPDATE → actualización NC/intento → stock cuando corresponde → UPDATE ventas |
| tributario_finalizar_proceso | proceso FOR UPDATE → solicitudes → comprobantes/NC → ventas y reversión de stock |

El orden efectivo de efectivo no coincide con caja→venta propuesto en sección 6. No se ha demostrado un deadlock mediante dos sesiones; la incompatibilidad debe resolverse antes de añadir un escritor que tome venta/cuenta antes de NC. La finalización fiscal además actualiza monto_notas_credito/estado_tributario, fuera de las actualizaciones saldo/estado autorizadas por las intenciones actuales. La guarda de cuentas abiertas no debe relajarse para permitir ese UPDATE legacy.

Se comprobó el inventario de 12 funciones mediante la consulta reproducible en `docs/saas/sql/financial_2c6b_writer_inventory.sql`. Los cuatro escritores internos de cobro/reverso/expediente no tienen EXECUTE para authenticated ni service_role; finalizadores fiscales sí permiten service_role. Esto impide conectar el núcleo privado simplemente desde el cliente o ampliar permisos como solución.

**Orden de trabajo para completar 2C6B:**
1. Completar grafo de escritores anidados y cierres de caja; fijar un único orden para operaciones de una y varias ventas.
2. Adaptar conjuntamente finalizadores NC/baja y escritores financieros; revalidar el vínculo documento–venta–empresa después de bloquear, manteniendo validación de token fiscal e idempotencia.
3. Extender intención transaccional, auditor y deduplicación por documento/transición; emitir ajuste y compensación de baja sin modificar pagos originales.
4. Persistir reducciones de cuotas y reclasificación del excedente; actualizar proyección y compatibilidad en la misma transacción.
5. Probar NC/cobro, NC/baja, cierre/efectivo, repetición y rollback en sesiones concurrentes reales; exigir CI 7/7 antes de activar.

No se modificaron funciones ni datos de Supabase en esta revisión. El CI 7/7 anterior corresponde a 2C6A y no acredita estos pendientes.

## 22. 2C6B1 — sesión de efectivo antes de cuenta y venta

Implementado en DEV mediante `20261103133623_financial_2c6b_cash_lock_order.sql`. El escritor de efectivo adquiere sesión FOR UPDATE antes de cuenta y venta. Conserva validación JWT/empresa, idempotencia, permisos privados, caja FOR SHARE y preflight posterior a los locks. No cambia importes, pagos ni finalizadores fiscales.

31 aserciones del contrato de efectivo aprobadas con ROLLBACK (28 existentes y tres comprobaciones estructurales de orden). Las tres comprobaciones nuevas no equivalen a una prueba concurrente. **CI 7/7 SUCCESS**, ejecución 41645908532. Candidato fuente 8231b6d049c905ccb6a660386fb3e648685c09c2, espejo 65a8242112882329be8ee8cffe668a5d92f32a09. Validación backend y compilaciones Android/Windows/Linux/macOS/iOS completas; no acredita todavía concurrencia específica NC/cobro/baja.

2C6A permanece cerrado con CI 41576975707, 7/7. 2C6B continúa parcial: faltan finalizadores NC/baja, ajuste canónico con cuotas/excedente y concurrencia específica. No se habilita UI ni API cliente.

## 23. 2C6B2 — coordinación de finalizadores fiscales

DEV: migración `20261103165943_financial_2c6b_nc_finalize_lock_order.sql`.
nota_credito_finalizar y tributario_finalizar_proceso adquieren el mismo advisory lock transaccional por empresa (financial-fiscal-transition) antes de locks de filas. La NC toma cuenta y venta antes de la nota y revalida venta_id después del bloqueo; un cambio produce 40001. Se conservan firmas, ACL, tokens e idempotencia existentes.

El bloqueo común serializa estas finalizaciones incluso para ventas distintas de una misma empresa; es una medida conservadora y no una prueba de ausencia de deadlocks en todos los escritores. El futuro escritor canónico debe usar el mismo bloqueo antes de cuenta/venta/NC. Las bajas conservan su orden interno bajo esta exclusión mutua. Faltan auditoría de llamadas directas/anidadas y pruebas reales de dos sesiones.

42 comprobaciones del contrato fiscal aprobadas en DEV (39 existentes, 3 estructurales de orden). CI **7/7 SUCCESS**, ejecución [41679887592](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41679887592). Source validado 41cfbf2bffad91c0352e2947d4a031c992c0d476; espejo d7e4372252f17d075196f63ed3f2dcd4534f2935. No se afirma validación funcional concurrente ni aplicación canónica de NC. Se mantiene el bloqueo de escrituras legacy para cuentas abiertas; no se relajaron guardas para actualizar monto_notas_credito. 2C6B continúa parcial.

## 24. 2C6B cerrado — aplicación y baja canónicas

La migración `20261104002417_financial_2c6b_atomic_credit_notes.sql` integra los finalizadores fiscales existentes con el ledger, sin nuevos RPC cliente. La intención privada está ligada a transacción, empresa, venta y NC; la aceptación crea un evento único negativo de exigible. Conserva total original y pagos, reduce pendientes en orden inverso de vencimiento y libera asignaciones cuando aparece excedente. La baja crea el evento compensatorio enlazado al original, restaura obligaciones y reasigna cobros disponibles según el estado actual, incluso con otras NC posteriores. Audita el batch completo antes de terminar. Cualquier fallo revierte documento, operación, evento, proyección y cuotas.

Se mantiene el gate fiscal por empresa y orden cuenta→venta, compatible con los escritores de cobro. Las fechas de aceptación/baja se toman al ejecutar la transición para evitar invertir su cronología al esperar un lock. Las cuotas totalmente reducidas pueden coexistir con cobros posteriores en cuotas que aún tienen deuda. No se desembolsan excedentes ni se abre UI. Las cuentas heredadas no conciliadas y cronogramas posteriores a v1 siguen rechazados; el reverso íntegro de transferencia continúa exigiendo asignaciones conciliadas.

**Cierre verificado el 2026-11-03 (America/Lima):** [CI 41711330018](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41711330018), 7/7 SUCCESS. Source validado `8e0ca91f493d273c3eb7e8cb3d5634973a57333a`, espejo `7bc3cc9276471469433b5230e80ec67712c8961c`. Dos reconstrucciones completas: 62 archivos pgTAP / 1.297 aserciones en cada una; ocho carreras de dos sesiones reales aprobadas (ambos órdenes NC/cobro, baja/cobro, NC/baja, reintentos y empresas independientes). Incluye 36 casos del nuevo contrato y cinco de baja por lote. También pasaron lint, ausencia de drift, restauración, aislamiento y compilaciones de clientes.

Aplicado en Supabase DEV `iqooedpkihmzkmynsisl` con versión efectiva `20261104002417`. El archivo generado originalmente por CLI como `20261103195344` se renombró para coincidir con el historial remoto; SQL idéntico al candidato CI. En DEV pasaron 30 aserciones funcionales y cinco de baja por lote, siempre con ROLLBACK; las seis aserciones de fallo tardío mediante trigger temporal se ejecutaron en CI (la solicitud de confirmación de esa variante en DEV expiró). Comprobación final: cero cuentas, intenciones y reclasificaciones de fixture. Los seis cuerpos de función instalados coinciden con la migración.

Advisors: sin WARN/ERROR nuevos. Dos INFO nuevos por RLS sin políticas en las tablas privadas de intención e historial; es deliberado, con permisos revocados a clientes y servicio. [Referencia del aviso](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy). Los avisos anteriores permanecen fuera de este bloque.

Siguiente bloque: 2C5B-B, reservas y liquidación de excedentes con evidencia de fondos, autorización y egreso real. Este cierre no ejecuta devoluciones ni habilita clientes.

## 25. Fase 2C5B-B — reserva, liquidación y retorno documentados (cerrada)

Migración `20261104010306_financial_2c5b_refund_settlement.sql`. Implementa un flujo interno completo de contabilidad de devolución: reserva parcial del excedente por expediente, liberación, registro de egreso de caja o banco con evidencia, y retorno compensatorio enlazado al egreso. La reserva consume disponibilidad de excedente pero no inmoviliza fondos físicos. Toda liquidación vuelve a comprobar excedente, estado de NC, permisos y fondos bajo bloqueo. Los importes son PEN y centavos exactos. No modifica ni elimina pagos originales.

`private.financial_refund_command(uuid,uuid,text,jsonb)` admite `reserve`, `release`, `bank_reconcile`, `settle`, `reverse`; identidad y empresa derivadas del JWT, permiso `tenant.admin`, request idempotente por empresa con huella del actor/acción/payload. `private.financial_refund_status(uuid,bigint)` distingue excedente, reserva, disponible y entregas netas; no autoriza el egreso a partir de una lectura. Todas las funciones nuevas y tablas privadas mantienen permisos revocados a PUBLIC/anon/authenticated/service_role y RLS sin políticas de acceso cliente.

El banco usa conciliaciones documentadas y un registro inmutable de movimientos. Requiere referencia única, SHA-256 del documento y fecha de ejecución para conciliación, egreso y retorno. **Registra evidencia aportada por un operador autorizado; no verifica documentos contra un banco ni envía transferencias.** El payload de respuesta indica `external_transfer_sent=false`. No se inventan fondos a partir de la NC: sin una conciliación bancaria explícita o saldo disponible en la sesión propia abierta, el egreso falla. El retorno acredita fondos solamente cuando se registra su evidencia; no es una anulación silenciosa del pago.

La sesión de efectivo debe pertenecer al administrador y a un empleado activo de la sucursal/caja activa. El saldo disponible y `get_estado_caja_chica` descuentan devoluciones y añaden retornos. El retorno a una sesión cerrada queda bloqueado. No habilita UI, RPC cliente, proveedor bancario ni envío real de fondos.

La protección de excedente reservado se ejecuta en la cuenta financiera, por lo que también protege frente a NC/bajas y reversos de cobro. Para una baja que necesite consumir reserva, primero debe liberarse la reserva; después de una devolución ya liquidada, la baja puede reabrir deuda. Un retorno posterior reasigna cuotas para conciliar esa deuda. Orden de locks: identidad de request → fuente de fondos (sesión/banco) → cuenta → venta → reserva. Evidencia y comandos son inmutables. La auditoría compartida verifica los eventos de devolución/retorno y su vínculo con el registro de fondos.

**Cierre 2C5B-B — 2026-11-03 (America/Lima), GitHub Actions 41752361125: 7/7 SUCCESS.** El candidato probado fue el source original `1ad2f026ad641cb1aabd1e7c1d4172a193e4e14c`, reproducido en el espejo CI `9854d70db5ee130c10bab58712c15912f5cdab7e`. Pasaron backend PostgreSQL (reconstrucciones limpias, pgTAP, ausencia de drift y restore), Flutter/Android, Windows, Linux, macOS/iOS, controles estáticos y resumen. Incluye las nueve carreras concurrentes de dos conexiones PostgreSQL (reservas, bajas, egresos, fondos y cierre de caja).

**Supabase DEV:** proyecto `iqooedpkihmzkmynsisl`, región `sa-east-1`. Migración `20261104010306_financial_2c5b_refund_settlement.sql` aplicada y registrada con **la misma versión 20261104010306**. Se ejecutaron sobre DEV las dos suites SQL originales reversibles: 32 aserciones de liquidación bancaria y 17 de caja, **49/49 aprobadas**. Ambos scripts finalizaron en `ROLLBACK`; la comprobación posterior confirmó que no permanecieron las ventas de fixture. El historial de migración, tablas, triggers y RPCs nuevos quedó validado en DB. Las cinco tablas `private.refund_*` tienen RLS activo y cero privilegios de SELECT/INSERT/UPDATE/DELETE para `anon`, `authenticated` y `service_role`; las funciones `private.financial_refund_command` y `private.financial_refund_status` carecen de EXECUTE para esos tres roles. El flujo continúa estrictamente interno.

**Advisors:** aparecen cinco avisos INFO de RLS sin políticas en tablas privadas nuevas; son intencionales y seguras por los REVOKE. Se identifican cuatro avisos INFO nuevos de claves foráneas sin índice de cobertura, a optimizar antes de alto volumen: `refund_fund_movements` (sesión, evento, reserva) y `refund_reservations` (expediente). Persisten advertencias WARN generales en otras partes del proyecto; no se consideran resueltas por este cierre. [Referencia de índices FK](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys).

**Límites de alcance:** se contabilizan egresos con evidencia aportada, sin conexión ni verificación automática de transferencias bancarias. No se habilitan API/RPC cliente, UI de devolución ni operaciones reales; no se hace GO de producción. Siguiente prioridad: completar el contrato de creación de ventas a crédito y cuotas versionadas, y después la integración segura de lectores/reportes y UI; antes de activar egresos públicos se requiere diseño de autorización del operador, evidencia validable y reconciliación bancaria/caja.

## 26. Fase 2D-A — venta interna a crédito con cronograma v5 (candidato de desarrollo)

Migración `20261104025000_financial_2d_credit_sale_v5.sql`. El RPC autenticado `public.process_sale_credit_v5` añade un contrato sin sobrecargas que recibe `p_credit_terms` con cuotas numeradas 1..N, monto exacto de dos decimales y fecha ISO local America/Lima posterior a la venta; admite vencimientos iguales en cuotas consecutivas. El preflight privado `private.financial_2d_validate_terms` verifica `SUM(cuotas) = total - abono` con cero céntimos de tolerancia. Para evitar pagos no conciliados, 2D-A permite abono inicial únicamente por transferencia o un abono cero. El RPC rechaza boleta/factura electrónica a crédito: solo `ticket_interno` hasta el gate normativo SUNAT de fase 3.

La misma transacción llama `process_sale_v4` o `process_sale_with_units_v4` según configuración de unidades, preserva stock, permisos y descuentos vigentes, y crea la cuenta financiera con apertura `historico_auditado`, eventos originales de abono, cronograma versión 1 y sus cuotas, con auditoría `private.financial_2c_audit_sale` obligatoria antes del commit. La proyección `ventas.fue_credito` se marca explícitamente. Idempotencia serializada por `request_id` y huella de payload/actor/empresa; la reutilización divergente falla antes de crear una segunda venta. Cualquier inconsistencia revierte venta, pagos, stock, ledger y cronograma.

Se conecta `VentaProcessingRequest.creditTerms` desde `venta_application_providers.dart` hacia `ventas_repository.dart`, con serialización `p_credit_terms` y validación anticipada en `ValidateSaleUseCase`. Los RPC v4 continúan para clientes legacy sin cronograma. Se clasifica el RPC nuevo dentro del gate `verify_saas_sales.mjs` y `verify_saas_rpc_surface.mjs`; no se acepta `organization_id` suministrado por Flutter.

Prueba reversible `financial_2d_credit_sale_v5_contract_test.sql`: **23/23** aserciones ejecutadas sobre Supabase DEV en una transacción de prueba que finalizó en ROLLBACK; validan dos cuotas, cuota única, fechas, fracciones, sumas, permisos e identidad ausente. **Limitación:** esta suite prueba el preflight y la superficie de autorización, no constituye aún una venta E2E real de stock + abono + cuota con lectura del cronograma. Falta gate de E2E positivo antes de habilitación comercial.

**Supabase DEV — verificación real (2026-11-03, America/Lima):** la migración `20261104025000_financial_2d_credit_sale_v5` quedó aplicada y registrada en `iqooedpkihmzkmynsisl`. Las 23 pruebas SQL reversibles pasaron nuevamente en DEV, sin dejar ventas de fixture. Comprobados RPC visible, `EXECUTE` únicamente en authenticated y validador privado inaccesible a clientes. La auditoría de seguridad registra un WARN nuevo `authenticated_security_definer_function_executable` por la función pública privilegiada, que exige revisión específica antes de producción; no se considera resuelto por CI. **Cierre de implementación 2D-A (CI 2026-11-03, America/Lima):** [GitHub Actions 41766118344](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41766118344), **7/7 SUCCESS**. Validó fuente original `b6bb5e6a6e286cf96254d00fbf9299fdaaa3fc88`, candidato espejo `7f19f3be36402d04ffdab8520d1afbf76d9ebbc5`. Pasaron backend PostgreSQL con dos reconstrucciones y pgTAP, cero drift, restore, concurrencia, aislamiento multiempresa, formato/análisis/pruebas Flutter y compilaciones Android, Linux, Windows, macOS e iOS; controles estáticos y resumen CI en verde. La migración v5 está desplegada en DEV y las 23 comprobaciones reversibles también pasaron allí. **La validación integral de negocio sigue abierta:** falta una prueba E2E positiva de venta a crédito con stock, cobro y lectura de cuotas antes de habilitar comercialmente. No marcar 2D, crédito electrónico, pagos en efectivo iniciales ni UI completa como terminados. Siguiente dependencia: 2D-B, lectura autorizada y prueba E2E de venta con ambas modalidades de unidades, pago inicial, reverso y cuadro de cuotas; posteriormente fase 3 para fiscal SUNAT.


## 27. Fase 2D-B — lectura protegida y venta real de prueba (DEV; CI pendiente)

**Fuente:** rama `feature/saas-multitenant-foundation`. Migración aditiva `20261104174500_financial_2d_b_credit_schedule_reader.sql` aplicada y registrada en Supabase DEV `iqooedpkihmzkmynsisl` el 2026-11-04. Agrega `public.obtener_cronograma_credito_v1(p_venta_id bigint)` como `STABLE SECURITY INVOKER` con `search_path=''`, autorización de `tenant.read` fail-closed incluso cuando es `NULL`, tenant derivado desde la identidad del usuario y protección RLS en venta, cuenta, cronograma, cuota y movimientos. El resultado incluye moneda, exigible, cobros netos, saldo, excedente, revisión, versión del cronograma y cuotas ordenadas con estado, vencimiento y saldo. Rechaza cuentas no conciliadas o cronogramas contradictorios; para venta legacy/no autorizada devuelve null. Solo `authenticated` recibe EXECUTE; `anon` no. No se creó otro `SECURITY DEFINER`.

**Flutter:** `VentasRepository.obtenerCronogramaCredito(ventaId)` usa un RPC con nombre literal y sin `organization_id` controlado por cliente. `obtenerVentaCompleta` agrega la clave opcional `credito` sin eliminar `venta`, `detalles` ni `pagos`. Ambos entrypoints están clasificados en los gates estáticos de ventas y de superficie RPC.

**Evidencia DEV (reversible):**
- `financial_2d_b_credit_schedule_reader_contract_test.sql`: **10 verificaciones** de grants, `SECURITY INVOKER`, saldo exacto, cuotas ordenadas, lectura con rol `authenticated` y aislamiento ORG_A/ORG_B, identidad inexistente y ausencia de membresía.
- `financial_2d_b_credit_sale_e2e_contract_test.sql`: **ejecución positiva del RPC real v5 (no mock)** sobre dos ventas sintéticas en una organización sintética con empleado autenticado, inventario y producto de prueba. Primera venta S/ 100 sin abono, una cuota y stock 15→14; segunda venta S/ 100 con abono por transferencia de S/ 20, dos cuotas de S/ 40 y stock 14→13. Repetición exacta del `request_id` devolvió resultado idempotente y no descontó stock ni duplicó cobros. La lectura autenticada del cronograma de la segunda venta devolvió pendiente S/ 80 y cobros S/ 20. Ambas suites se ejecutaron en transacciones `BEGIN ... ROLLBACK` sobre DEV; comprobación posterior encontró **0 organizaciones y 0 productos** sintéticos persistentes.
- Comprobación final en DEV: migración registrada, RPC existente, invoker=true, `authenticated` permitido y `anon` bloqueado. Advisors de seguridad sin avisos nuevos; siguen los WARN anteriores, incluido `authenticated_security_definer_function_executable` del escritor v5 (2D-A), sujeto a revisión previa a producción.


**Ampliación 2D-B validada en DEV (2026-11-04, exclusivamente desarrollo):** la suite de venta E2E fue extendida a **21/21** tests pgTAP y la suite de lectura mantiene **10/10** (total **31/31**), todos reversibles. El tercer caso atraviesa efectivamente `process_sale_with_units_v4` desde el escritor v5 utilizando un perfil de presentación persistido revisión 1: **1 caja = 2 unidades base**; snapshot del detalle `code=caja, factor=2, revision=1`, inventario sintético 13→11, cronograma v1 con dos cuotas de S/100 y cuenta conciliada por S/200. A continuación se registró un cobro por transferencia de S/50 con el motor 2C2, se comprobó asignación FIFO a cuotas y saldo S/150, y se revirtió con 2C5A: saldo restaurado S/200, cobros netos cero y movimientos de cuotas compensados. Esto prueba reverso de **cobro posterior**, no reverso del **abono inicial** de v5; este último sigue pendiente de contrato de reversiones y cronograma versionado.

**CI cerrado en desarrollo — 2026-11-04:** [GitHub Actions 41896721219](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41896721219) completó **7/7 SUCCESS** sobre el source original `71ab41596f0a81c9cee6481bbf22874165a0a2e7`, reproducido en el espejo `fa62afbf6fa9ff2ce3bd40ccdc92af4973e0528d`. Pasaron backend PostgreSQL con reconstrucciones dobles, pgTAP (incluidas las 31 pruebas 2D-B), lint, ausencia de drift, multiempresa E2E, carreras de concurrencia, backup/restore y segunda validación; Flutter/Android, Windows, Linux, macOS/iOS, controles estáticos y resumen final. La primera ejecución 41883338399 había fallado por interrupción de red al descargar la clave PGDG; se corrigió el workflow de ambos repositorios con reintentos y fuentes alternativas. También se corrigió el contrato pgTAP de 2D-B usando `plan`, `ok` y `finish`. **2D-B está implementado, desplegado solo en DEV y validado técnicamente en CI.** Los avisos anteriores del asesor de seguridad continúan abiertos para su atención específica.

**Límites:** no desplegar en producción, no habilitar crédito electrónico SUNAT, no publicar reverso de abono inicial ni habilitar egresos reales. Antes de habilitación comercial revisar el escritor v5 `SECURITY DEFINER`, permisos para cliente, validación de transferencias y contrato específico de reverso de anticipo.

## 28. Fase 2D-C — reverso contable del abono inicial v5 y cronograma compensatorio (DEV / candidato CI)

**Alcance:** migración `20261104212500_financial_2dc_initial_downpayment_reversal.sql`. La nueva función **privada** `private.financial_2dc_reverse_initial_transfer` NO es un RPC de cliente, no realiza transferencias ni egresos bancarios y revoca EXECUTE a `PUBLIC`, `anon`, `authenticated` y `service_role`. El backend de confianza deberá verificar **fuera de esta función** que el banco efectivamente anuló la transferencia antes de entregar una referencia de reversión; una referencia textual por sí sola NO acredita al banco. No habilitarla aún para usuarios ni producción.

El escritor interno exige actor autenticado, organización derivada del contexto, permiso `sales.collect`, coincidencia entre cliente y libro PEN conciliado, solicitud y referencia idempotentes, venta originada en `venta_credito_v5`, un único abono inicial de transferencia y cronograma v1 limpio de movimientos, sin operaciones posteriores (NC, cobros u otros). Rechaza fechas inconsistentes, reparto incompatible, reintento divergente, otro tenant y doble reversión. Usa lock de cuenta/venta, journal `reverso` vinculado con su `pago_id` y evento original, intención de escritura privada, actualización de saldo/cobros y auditoría `financial_2c_audit_sale`. No elimina pago, venta, cuota ni evento original.

**Versionado de obligaciones:** el cronograma original pasa a `sustituido` y retiene sus cuotas, IDs de obligación y fechas, sin mutaciones históricas. El nuevo `vigente` es versión 2: reproduce las cuotas originales y agrega una última cuota de importe exactamente igual al abono revertido (vencimiento igual al último vencimiento), sumando el nuevo saldo. Su `origen_evento_id` apunta a la reversión. Un verificador privado `financial_2dc_supported_v2_schedule` exige esa procedencia y ausencia de asignaciones en v1. **Solo para esa procedencia certificada**, el asignador 2C4 y el reversor posterior 2C5A aceptan v2; demás versiones continúan bloqueadas.

**Pruebas reversibles realizadas en Supabase DEV:** `financial_2dc_initial_downpayment_reversal_contract_test.sql` **20/20 pgTAP** sobre escritor v5 real, reverso de S/20 de una venta S/100, v1 conservado (S/80), v2 con cuotas S/40 + S/40 + S/20 (saldo S/100), idempotencia, posterior cobro de S/10, asignación y reverso de ese cobro; negativas para evento forjado, referencia inválida, tenant ajeno, reintento divergente, segundo reverso y ausencia de JWT. Regresión bajo la misma migración: `financial_2d_b_credit_sale_e2e_contract_test.sql` **21/21**, `financial_2d_b_credit_schedule_reader_contract_test.sql` **10/10**. Las tres suites terminan en `ROLLBACK`, sin datos sintéticos persistentes. Total **51/51** aserciones DEV en estas suites.

**Estado: 2D-C IMPLEMENTADO, CI 7/7 Y DESPLEGADO EN DEV (2026-11-04).** [Ejecución GitHub Actions 41914285244](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41914285244): **7/7 SUCCESS** sobre source `071df2f473e2cf7534618ff5fd7eec4262dcedd9` y espejo `c01cd34bf7c8e87fade3e0c70d5d9b05c2b0e6f3`. Pasaron PostgreSQL, pgTAP, 2 resets, lint/drift, multiempresa, concurrencia, backup/restore y compilaciones Flutter/Android/Windows/Linux/macOS/iOS. Migración `20261104212500` aplicada y registrada en Supabase DEV `iqooedpkihmzkmynsisl`. Pruebas repetidas contra la instalación persistente: **20+21+10=51/51 pgTAP**, con `ROLLBACK`. Privilegios verificados: `anon`, `authenticated` y `service_role` sin EXECUTE; `SECURITY INVOKER` y ningún fixture sintético sobreviviente. Advisors de seguridad sin advertencias adicionales; advertencias generales previas siguen abiertas. Mantener fuera de alcance la verificación bancaria externa real, pagos iniciales en efectivo, NC o baja sobre v2, modificaciones después de pagos parciales y otros cambios generales de cronograma. Resolver auditoría del escritor v5 `SECURITY DEFINER` antes de lanzamiento comercial.

## 29. Fase 2D-D — NC y baja financiera sobre cronograma v2 certificado (solo DEV)

**Implementación:** migración `20261105002000_financial_2dd_certified_v2_nc_compat.sql`. El escritor **existente** `private.financial_nc_apply_transition` y el preanalizador **existente** `private.financial_2c6a_preview_credit_note` ahora aceptan exclusivamente cronogramas originales v1 o cronogramas v2 cuyo origen acredita `private.financial_2dc_supported_v2_schedule`. Cualquier versión posterior, tenant ajeno, historial v2 manipulado o v2 sin reverso inicial auditado sigue bloqueado. La mutación financiera de una NC sobre v2 se aplica únicamente a las cuotas vigentes; las cuotas e importes de v1 `sustituido` quedan intactos. El reajuste financiero por baja restaura exactamente el principal de las cuotas v2 y genera un evento `reversion_ajuste`, sin borrar el historial.

**Endurecimiento de permisos:** `public.process_sale_credit_v5`, que conserva `SECURITY DEFINER` por necesitar escritura sobre tablas de ledger no expuestas, ahora exige `public.app_tiene_permiso('sales.create') IS NOT TRUE` como fallo explícito y seguro ante un permiso nulo. Se conservan el `auth.uid()` obligatorio, organización derivada por `private.require_current_organization_id()`, `search_path=''`, idempotencia por huella y autorización `authenticated` (no `anon`). **Esto NO implica que desaparezcan las advertencias globales del asesor Supabase ni sustituye una auditoría de penetración.**

**Pruebas reversibles DEV:** `financial_2dd_certified_v2_nc_contract_test.sql` pasa **24 aserciones** sobre venta v5 real sintética, reverso de anticipo v2 certificado, previsualización de NC S/30, finalización financiera real de NC S/100→S/70, cuotas v1 inmutables, tenant incorrecto, venta incorrecta, procedencia v2 falsificada, versión 3 rechazada y compensación financiera por baja S/70→S/100. La baja se prueba a nivel **transición contable con intención privada simulada**, no como aprobación fiscal SUNAT. Regresiones en la misma transacción: 2D-C 20, 2D-B E2E 21, 2D-B lector 10 y crédito v5 23; **98 comprobaciones** reversibles, sin tocar clientes ni producción.

**Límites expresos:** La venta v5 continúa siendo **ticket_interno**; el fixture fiscal de pruebas NO constituye emisión SUNAT. No habilitar boletas/facturas electrónicas a crédito ni devoluciones bancarias a partir de esta prueba. Las referencias de transferencias y reversos aún necesitan verificación de una institución externa, conciliación bancaria y mecanismo confiable de atestación. La NC versionada posterior a cobros con más versiones no está habilitada. No añadir acceso público a los escritores privados.

**Estado inicial:** código y suite de DEV escritos; pendiente CI 7/7 y aplicación persistente de la migración al único proyecto Supabase DEV (`iqooedpkihmzkmynsisl`). Jamás aplicar en producción.
