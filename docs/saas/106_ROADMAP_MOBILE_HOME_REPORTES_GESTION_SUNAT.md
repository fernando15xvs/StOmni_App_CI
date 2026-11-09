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

**2D-C cerrado técnicamente en desarrollo (2026-11-04):** migración `20261104212500` de reverso contable **privado** del abono inicial por transferencia de v5, con evento compensatorio y cronograma versión 2. Se conserva v1 inmutable y solo se admite v2 de procedencia certificada para cobros posteriores y sus reversos. **51/51 aserciones pgTAP reversibles ejecutadas y aprobadas en Supabase DEV tras el despliegue persistente** (20 nuevas + 21 y 10 de regresión). [CI 41914285244](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41914285244): **7/7 SUCCESS**. Permisos privados verificados, sin datos sintéticos persistentes. Siguiente paso: evidencia externa bancaria, auditoría del escritor v5 `SECURITY DEFINER` y contratos de NC/baja sobre cronograma v2; sin producción, SUNAT crédito, egresos reales ni UI de reverso del anticipo. Véase documento 108 §28.

**2D-D cerrado técnicamente en desarrollo (2026-11-04):** NC y compensación contable de baja sobre cronograma v2 **exclusivamente certificado** por reverso inicial 2D-C, manteniendo v1 histórico inmutable y rechazando versiones inválidas; escritor v5 reforzado con permiso `sales.create IS NOT TRUE` y concesiones explícitas mínimas. Migración `20261105002000` **aplicada en Supabase DEV**, cinco suites **100/100 pruebas pgTAP reversibles** tras despliegue (26 nuevas + 74 regresiones). [CI 41918768327](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41918768327): **7/7 SUCCESS** sobre source `0b05dd7c`, espejo `d1683bb`. Aún pendiente: verificación bancaria institucional, fiscalización/aceptación real SUNAT, auditoría externa de `SECURITY DEFINER` y casos de NC con cobros concurrentes sobre v2. **Prohibido producción y emisión electrónica de crédito**; el escenario de baja fue contable sintético, no aprobación SUNAT. Documento 108 §29.

**2D-E cerrado técnicamente en desarrollo (2026-11-04):** siete carreras reales entre dos sesiones sobre NC/cobros/baja del cronograma v2 certificado (solo loopback) y corrección de unicidad global de nombres/códigos de productos y DNI/RUC de clientes con migración `20261105010000` aplicada exclusivamente en Supabase DEV. Índices únicos por organización conservados, sin residuos sintéticos. [CI 41932512909](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41932512909): **7/7 SUCCESS** (71 archivos, 1.469 aserciones pgTAP en CI, 7 carreras nuevas, restauración, Linux/Windows/macOS/iOS/Android); **123 comprobaciones reversibles** repetidas contra DEV ya migrado. Permanece pendiente verificar evidencia bancaria externa, emisión/aceptación fiscal SUNAT, revisión exhaustiva de funciones con `SECURITY DEFINER` y posible unicidad global de `empleados.app_user_id` para membresía multiempresa. **Sin producción ni movimientos bancarios reales.** Detalles: documento 108 §30.

**2D-F cerrado técnicamente en desarrollo (2026-11-04; NO producción):** migración `20261105023000` instalada y registrada únicamente en Supabase DEV: atestación bancaria privada/inmutable y consumo único obligatorios antes del reverso del anticipo, con empresa/venta/evento/importe/referencia vinculados y denegación sin evidencia. Se fijó `search_path` del trigger de clasificación documental y desapareció esa advertencia del asesor; las demás funciones privilegiadas requieren auditoría. [CI 41936615014](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41936615014) **7/7 SUCCESS**: siete carreras v2 y regresiones. Tras despliegue se repitieron **131/131 comprobaciones reversibles** y no quedaron registros sintéticos. **No hay todavía conexión ni verificación de firma bancaria externa**; una huella SHA-256 no prueba identidad de un banco y una atestación debe ser introducida por un proceso de conciliación verificado de confianza. `app_users.user_id` y `empleados.app_user_id` siguen imponiendo identidad de una sola empresa; su modificación exige rediseño conjunto de membresía y RLS. Próximo: trabajador de conciliación con proveedor real y auditoría sistemática de funciones con `SECURITY DEFINER`. Sin emisión electrónica de crédito, transferencias reales ni cambios en producción. Documento 108 §31.

**2D-G cerrado técnicamente en desarrollo (2026-11-04):** auditoría de 101 RPC con `SECURITY DEFINER` ejecutables por usuarios autenticados y corrección de tres riesgos concretos: rol cruzado de `get_user_role`, movimientos financieros interempresa en `obtener_tendencia_movimientos` y resolución de precios ajenos en `resolve_sale_price_v1`. `app_tiene_permiso`, `get_my_effective_permissions_v1` y `_gre_empleado_activo` requieren simultáneamente `activo=true` y `employment_status='active'`. Migración `20261105030000` **aplicada exclusivamente en Supabase DEV**, con **150/150 pruebas reversibles** (19 nuevas de seguridad, 131 financieras y catálogo). [CI 41941086791](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/41941086791) **7/7 SUCCESS**; se normalizaron finales CRLF del SQL del primer candidato que causaron error del control de dependencias Android. Auditoría posterior confirma que no quedaron datos sintéticos. **Pendiente:** revisión RPC por RPC de las 101 advertencias, rediseño completo de identidad multiempresa, validación externa bancaria y SUNAT crédito; sin cambios en producción. Documento 108 §32.

**2D-H en curso — bloque de aislamiento y empleo validado en DEV (2026-11-05, America/Lima).** El candidato privado `c27519f62159c4dabafcb9c9530613c14bef5857` corresponde al espejo `93bfd1c81e591ad72a75face4d888ef1f5c614ef`. [CI 42102264203](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/42102264203), intento 2, terminó con sus siete trabajos en `success`. La migración `20261105201748_security_2dh_active_employment_fiscal_void.sql` está registrada en Supabase DEV `iqooedpkihmzkmynsisl`. La baja tributaria exige un administrador con empleo activo y rechaza al administrador terminado incluso cuando conserva `activo=true`, antes de validar el documento.

Las pruebas de aislamiento entre dos empresas válidas pasaron **29/29**, con administrador y operador de permisos distintos, identificadores cruzados, lotes mixtos, catálogo, permisos, pagos, gastos y traslado de stock. Las cuatro pruebas de empleo fiscal pasaron **4/4**. El contrato de superficie privilegiada pasó **2/2**. La lectura posterior del catálogo confirmó 218 rutinas privilegiadas en `public`, 101 ejecutables por `authenticated` y cero por `anon`.

La regresión posterior a la migración pasó **681/681 comprobaciones en 31 archivos**, obtenidos del SHA privado indicado. Cada archivo se ejecutó en una transacción con `ROLLBACK`. Para recuperar el resultado por el conector se resumió la salida final de pgTAP con `finish()`, `num_failed()` y `_get('curr_test')`; los contratos con aserciones que lanzan excepciones se resumieron contando su tabla temporal de comprobaciones. Los 27 contratos pgTAP devolvieron cero fallos y diagnósticos vacíos. Los cuatro restantes completaron todas sus aserciones. Una confirmación caducada del conector se reintentó satisfactoriamente antes de continuar.

| Contrato en `supabase/tests/database/` | Aprobadas |
|---|---:|
| `catalog_tenant_contract_test.sql` | 24 |
| `debt_payment_v2_contract_test.sql` | 17 |
| `financial_2a_tenant_ledger_contract_test.sql` | 27 |
| `financial_2b_guarded_legacy_opening_contract_test.sql` | 22 |
| `financial_2b_reconciliation_preview_contract_test.sql` | 15 |
| `financial_2c2_atomic_transfer_writer_contract_test.sql` | 33 |
| `financial_2c3_cash_permission_preflight_contract_test.sql` | 26 |
| `financial_2c3b_atomic_cash_writer_contract_test.sql` | 31 |
| `financial_2c4_atomic_installment_allocation_contract_test.sql` | 31 |
| `financial_2c4_cash_installment_integration_test.sql` | 14 |
| `financial_2c5a_cash_reversal_guard_contract_test.sql` | 14 |
| `financial_2c5a_full_transfer_reversal_contract_test.sql` | 29 |
| `financial_2c5b_cash_refund_contract_test.sql` | 17 |
| `financial_2c5b_internal_refund_case_contract_test.sql` | 23 |
| `financial_2c5b_refund_settlement_contract_test.sql` | 32 |
| `financial_2c6a_credit_note_preview_contract_test.sql` | 32 |
| `financial_2c6b_atomic_credit_note_contract_test.sql` | 36 |
| `financial_2c6b_batch_baja_contract_test.sql` | 5 |
| `financial_2c_strict_ledger_preflight_contract_test.sql` | 26 |
| `financial_2d_b_credit_sale_e2e_contract_test.sql` | 21 |
| `financial_2d_b_credit_schedule_reader_contract_test.sql` | 10 |
| `financial_2d_credit_sale_v5_contract_test.sql` | 23 |
| `financial_2dc_initial_downpayment_reversal_contract_test.sql` | 28 |
| `financial_2dd_certified_v2_nc_contract_test.sql` | 32 |
| `financial_2de_customer_document_tenant_uniqueness_contract_test.sql` | 7 |
| `financial_2de_product_tenant_uniqueness_contract_test.sql` | 10 |
| `fiscal_tenant_contract_test.sql` | 42 |
| `security_2dg_tenant_scoped_user_role_contract_test.sql` | 19 |
| `security_2dh_cross_tenant_operations_test.sql` | 29 |
| `security_2dh_definer_surface_contract_test.sql` | 2 |
| `security_2dh_fiscal_void_employment_test.sql` | 4 |
| **Total** | **681** |

**Pendiente de 2D-H.** Completar la revisión y evidencia RPC por RPC de las 101 funciones accesibles a usuarios autenticados, ampliando los casos positivos y negativos para las operaciones restantes. El conjunto anterior acredita las operaciones cubiertas. La identidad multiempresa sigue condicionada al rediseño conjunto descrito a continuación.

**2D-H — bloque de sucursales y cajas validado en DEV (2026-11-06, America/Lima).** Se corrigió una diferencia de errores de `update_cash_register_v1` que revelaba si una caja ajena tenía una sesión abierta. La migración `20261106014224_security_2dh_cash_register_tenant_preflight.sql` comprueba y bloquea primero la caja de la empresa actual, y filtra las sesiones por empresa. El contrato nuevo reproduce 1 fallo de 23 en la versión anterior y pasa 23/23 con la corrección.

Candidato privado `7ca6ee50b00e94ef4f1abb44058044d1f08f1b59`, espejo `6f4bf584ce4afbd5afc707dc49129340ff22724b`. [CI 42145855852](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/42145855852), intento 1, **7/7 success**. El backend ejecutó 1.554 pruebas en 76 archivos en dos ciclos de reconstrucción, ambos aprobados, además de las pruebas E2E, concurrencia y restauración. La corrección se aplicó en DEV después del CI completo.

La validación posterior al despliegue pasó **65/65 comprobaciones** en transacciones revertidas, con cero fallos y diagnósticos vacíos.

| Archivo en `supabase/tests/database/` | Aprobadas |
|---|---:|
| `security_2dh_branch_cash_tenant_test.sql` | 23 |
| `branches_tenant_contract_test.sql` | 16 |
| `cash_registers_tenant_contract_test.sql` | 24 |
| `security_2dh_definer_surface_contract_test.sql` | 2 |

El código instalado coincide exactamente con el cuerpo de la función del candidato. Se alineó el registro de migración creado por el conector, `20261106105204`, con la versión canónica del archivo de GitHub, `20261106014224`, tras comprobar la identidad del código. El asesor de seguridad conserva las 101 advertencias de funciones autenticadas pendientes de revisión individual. La matriz [SECURITY_2DH_RPC_AUDIT.md](SECURITY_2DH_RPC_AUDIT.md) registra las firmas, la cobertura disponible y el trabajo restante. **2D-H sigue en curso** por las filas pendientes y la revisión de auxiliares.

**2D-H — corrección de autorización por empleo activo en DEV (2026-11-06, America/Lima).** Se detectó que las RPC de alertas podían admitir a empleados desactivados: `private.current_base_role()` ignoraba el estado del empleado y `private.has_permission()` podía devolver `NULL`, que no activa el rechazo con `IF NOT ...` en PL/pgSQL. Se instaló exclusivamente en Supabase DEV la migración `20261106231519_security_2dh_active_employee_permission_gate.sql` para exigir `activo IS TRUE`, `employment_status='active'` y retornar `false` ante ausencia de autorización. La nueva regresión `security_2dh_operational_alerts_and_active_employment_test.sql` pasó **41/41 aserciones reversibles** con empresas A/B y permisos admin/operador, bloqueo de identificadores foráneos, aislamiento del inbox, cambio de estado, revisionado y revocación laboral. Se revisaron siete RPC de alertas y sus auxiliares; el registro pormenorizado está en `SECURITY_2DH_RPC_AUDIT.md`. **Pendiente:** nuevo run CI y auditoría de las demás funciones privilegiadas. No se modificó producción.

**2D-H — compatibilidad de fixtures financieros (2026-11-06).** La primera regresión integral del espejo `42311123809` encontró T04 rojo: cuatro contratos financieros antiguos lanzaban errores de autorización y el lector de cuotas fallaba 3/10 al presentar usuarios de prueba sin empleo activo. Se corrigieron los cinco archivos de contratos insertando empleados/sucursales activos en los fixtures legítimos; las comprobaciones reversibles de cada archivo ahora superan DEV. **No se debilitó la migración `20261106231519`.** Pendiente repetir el workflow completo para certificar el candidato actualizado. Sin producción.

**2D-H — endurecimiento adicional de contexto privilegiado (2026-11-07, solo DEV).** Se corrigió el acceso con membresía aún activa de un empleado despedido a lectores `SECURITY DEFINER` que solo exigían `private.require_current_organization_id()`. Migración `20261107161923_security_2dh_require_active_employment_for_tenant_context.sql` registrada en DEV, que ahora exige `private.has_permission('tenant.read') IS TRUE`. Se incorporaron los contratos `security_2dh_privileged_tenant_context_test.sql` (13/13) y `security_2dh_dynamic_privileged_rpc_smoke_test.sql` (101 RPC × 2 contextos y 9/9 aserciones agregadas). Nueve contratos seleccionados tras la migración sumaron 226/226 aserciones. Los argumentos NULL del smoke **no garantizan** revisar rutas positivas ni seguridad entre empresas, por lo que la auditoría individual y las políticas RLS de metadatos de cuenta siguen pendientes; issue #7. La ejecución del espejo `42311909785` (intento 2) superó las suites pgTAP 78 archivos/1.652 casos y los escenarios iniciales de carga/concurrencia, pero falló luego en una colisión de sucursal principal al montar fixtures de carreras de devolución. Se corrigió `scripts/run_financial_2c5b_concurrency_ci.mjs` para crear una sucursal secundaria cuando el fixture ya contiene una principal. **Falta certificar de nuevo en CI.** Sin producción, SUNAT crédito ni pagos reales.

**2D-H — revocación de metadatos y semántica de baja (2026-11-07; desarrollo, nunca producción).** Migración `20261107162850_security_2dh_preserve_revoked_guard_semantics.sql`: restaura volatilidad del helper de contexto y compatibilidad de `_gre_empleado_activo()` / validación fiscal sin reabrir lectura privilegiada a empleados revocados; 28/28 pruebas de compatibilidad. Migración `20261107163200_security_2dh_revoke_direct_tenant_metadata.sql`: RLS para `organizations` y `app_users` exige `tenant.read` con empleo activo; el endpoint de estado de alta informa `access_revoked` sin revelar empresa, y Flutter reconoce el nuevo estado. `security_2dh_account_state_rls_test.sql` 12/12 en DEV, con alta efectiva de empresa y administrador probada en una transacción revertida: sin regresión en F8.1. **Pendiente:** CI del candidato final y las 65 firmas aún sin revisión individual documentada, más 16 con revisión parcial. El smoke de 101 funciones no sustituye ensayos positivos, negativos y auxiliares para cada una. No cerrar falsamente 2D-H.

**2D-H — control estático del inventario (2026-11-07).** Se versionó `security_2dh_privileged_guard_classification_test.sql` con **11/11 aserciones DEV**: 75 firmas con contexto estricto, 20 con aserciones de permiso/pertenencia, 4 de identidad/alta, una delegada al escritor de traslado y una de catálogo público de planes. Vigila fijación de `search_path`, permisos de esquema y superficie de 101 firmas. Complementa el smoke de 202 invocaciones, pero no sustituye las pruebas de ejecución válida y aislamiento todavía pendientes en la matriz.

**2D-H — avance de auditoría por RPC y redacción de membresías huérfanas (2026-11-09, Supabase DEV).** Se agregó `security_2dh_reader_rpc_real_bootstrap_test.sql` (**19/19**) con dos altas reales (propietarios A/B) y 22 lectoras por cada una, además de denegación de 22 lectoras por JWT de empleado revocado y otras 22 por usuario sin empresa. El catálogo amplió `security_2dh_catalog_operations_test.sql` de **57 a 71/71** aserciones, con 14 pruebas nuevas sobre servicios, perfil de unidades, precios, mermas y traslado de stock, aislamiento de escritura y operador limitado. La nueva migración `20261109232121_security_2dh_signup_orphan_membership_redaction.sql` evita que una fila `app_users` sin ficha laboral activa exponga nombre/ID de la empresa en el estado de registro; `security_2dh_account_state_rls_test.sql` sube a **14/14** y el alta de empresa de extremo a extremo conserva propietario y contexto correctos en una transacción reversible. En total, **176/176** aserciones de siete suites afectadas y **52/52** adicionales de cuatro contratos pasaron en DEV.

**Estado concreto de 2D-H:** matriz de 101 funciones: **27 revisadas individualmente, 39 con cobertura parcial y 35 sin revisión individual**. El candidato anterior `42392621594` terminó **7/7 verde** en el espejo, pero fue anterior a estos últimos cambios. **No declarar cerrada esta fase hasta sincronizar el nuevo candidato, certificar CI y completar pruebas positivas, lotes mixtos y auxiliares de las 74 firmas no cerradas.** No hay intervención sobre producción; tampoco se habilitó multiempresa por identidad.

**Preparación de identidades.** La PK de `app_users(user_id)` y la unicidad de `empleados(app_user_id)` son globales. Ya existe una FK compuesta de empleado a membresía. Tanto `private.current_organization_id()` como `private.current_base_role()` buscan por usuario activo sin selector de empresa. Antes de admitir una segunda membresía, resolver organización y rol sobre la misma membresía elegida, validar su vigencia en cada operación y cubrir dos sesiones simultáneas, revocación y clientes actuales de una sola empresa. Revisar también el vínculo heredado `empleados.auth_id` y las políticas RLS dependientes. La última migración registrada en DEV es `20261107163200`; la resolución de identidad aún requiere este rediseño.

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

2C6B, 2C5B-B y los bloques 2D-A a 2D-G tienen evidencia registrada en sus apartados. El bloque de aislamiento y empleo de **2D-H** quedó validado en DEV con 681/681 comprobaciones y CI 42102264203 (7/7) para el candidato privado `c27519f6`. **Próximo paso dentro de 2D-H** — finalizar los 35 entrypoints pendientes y completar casos positivos, operadores y auxiliares de las otras 39 firmas parcialmente cubiertas; 27/101 ya tienen revisión individual documentada. El CI 42392621594 aprobó 7/7 para un candidato anterior, pendiente nueva certificación del cambio de 9 de noviembre. Después corresponde resolver la membresía seleccionada y su rol de forma conjunta antes de habilitar identidades multiempresa. Continúan pendientes la navegación de fase 1, la integración bancaria externa y la validación SUNAT de crédito según sus respectivos criterios.

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

