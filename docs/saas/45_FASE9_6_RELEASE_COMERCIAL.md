# Fase 9.6 — Release comercial

## Estado

**IMPLEMENTADA / GO COMERCIAL PENDIENTE DE T00–T19**

F9.6 cierra la implementación del proceso técnico de salida comercial sin ejecutar ningún despliegue ni fabricar evidencia de validación.

La fase deja versionados:

- runbook de release: `docs/saas/RELEASE_RUNBOOK.md`;
- plantilla T19: `docs/saas/FINAL_VALIDATION_REPORT_TEMPLATE.md`;
- gate de readiness: `scripts/verify_saas_release_readiness.mjs`.

No se ejecutó GitHub Actions, no se aplicaron migraciones SaaS al Supabase remoto, no se hizo merge y no existe autorización de producción derivada de esta fase.

## 1. Principio de cierre

F9.6 distingue tres conceptos:

1. **implementación del release process**: queda versionada en esta fase;
2. **validación final**: requiere ejecutar T00–T19 en local sobre el commit candidato;
3. **GO comercial**: sólo puede existir en `FINAL_VALIDATION_REPORT.md` después de completar la validación.

Por ello F9.6 puede marcarse `[x]` como fase implementada mientras `GATE BLOQUE 9 VERDE` y `StOmni listo para comercialización SaaS` permanecen abiertos.

## 2. Release Runbook

`RELEASE_RUNBOOK.md` define:

- freeze de commit candidato;
- pre-release de backend;
- orden de migraciones / Edge / clientes;
- secretos fuera de Git/Flutter;
- reglas Storage;
- soporte de plataformas derivado de T15;
- condición de billing real;
- backup/RPO/RTO;
- smoke post-release;
- release blockers;
- rollback/recuperación;
- observación posterior;
- evidencia que debe conservarse.

El runbook declara explícitamente que no constituye autorización de despliegue.

## 3. Plantilla del informe final

`FINAL_VALIDATION_REPORT_TEMPLATE.md` queda en estado `DECISIÓN: PENDIENTE`.

Incluye:

- commit y toolchain;
- tabla T00–T19;
- passed/failed/skipped;
- Flutter analyze/test;
- reset/pgTAP;
- matriz tenant A/B;
- E2E y dominio;
- builds/plataformas;
- performance F9.2;
- restore/RPO/RTO F9.3;
- observabilidad F9.4;
- seguridad F9.5;
- readiness F9.6;
- defectos/desviaciones;
- release blockers;
- decisión final.

La plantilla no se usa como sustituto del informe real: durante T19 deberá copiarse a `FINAL_VALIDATION_REPORT.md` y completarse con evidencia ejecutada.

## 4. Gate de readiness

`scripts/verify_saas_release_readiness.mjs` valida estáticamente:

- presencia de runbook, template, auditoría, mapa y checklist;
- que F9.6 figure implementada;
- que `GATE BLOQUE 9 VERDE` siga abierto antes de T00–T19;
- que el estado global no declare comercialización anticipadamente;
- que T02 ejecute el gate;
- que T19 siga presente y referencie la plantilla;
- que la plantilla incluya las 20 filas T00–T19 y campos críticos.

Si en el futuro existe `docs/saas/FINAL_VALIDATION_REPORT.md`, el gate también valida su decisión.

## 5. Defensa contra GO falso

Un `NO-GO` válido puede existir con pruebas pendientes/fallidas porque representa una decisión de no liberar.

Un `GO`, en cambio, es rechazado por el gate si falta cualquiera de estas condiciones estructurales:

- T00–T19 con estado verde/passed;
- `Pruebas críticas fallidas: 0`;
- `Pruebas críticas omitidas: 0`;
- evidencia `RESTORE_DRILL_GREEN`;
- confirmación de ausencia de `TENANT_ISOLATION_VIOLATION`;
- confirmación de ausencia de `PII_SECRET_LOG_EXPOSURE`.

Esto no prueba por sí solo que la evidencia sea verdadera: T19 sigue requiriendo revisión humana de logs, comandos y artefactos. El gate evita únicamente un cierre documental obviamente incompleto.

## 6. Billing comercial

F7 dejó una interfaz provider-agnostic. F9.6 no inventa proveedor, price IDs ni credenciales.

Antes de habilitar pagos reales debe existir una configuración/proveedor aprobado y probado. Si no existe, la monetización real debe permanecer deshabilitada o en el modo explícitamente aprobado; el resto del producto no debe fingir cobros.

## 7. Plataformas

F9.6 tampoco convierte plataformas no probadas en soportadas.

El soporte comercial se deriva exclusivamente de T15:

- Windows no certifica iOS/macOS;
- iOS/macOS requieren macOS;
- Linux requiere su build/smoke correspondiente;
- Android/Web/Windows requieren sus builds/smoke definidos.

## 8. Producción y migraciones

No se ejecutan desde esta fase.

Cuando exista un GO real:

1. congelar commit/tag;
2. tomar backup pre-release;
3. aplicar sólo migraciones versionadas aprobadas;
4. desplegar Edge/config del mismo candidato;
5. smoke backend;
6. distribuir sólo clientes/plataformas verdes;
7. smoke post-release;
8. monitorizar F9.4;
9. registrar cualquier rollback.

Una corrección posterior al GO genera un nuevo candidato y exige revalidar la superficie afectada.

## 9. Condiciones que mantienen el release bloqueado ahora

A fecha de implementación de F9.6 siguen pendientes por diseño:

- T00–T19;
- los gates de bloque que requieren runtime real;
- F2.5 suite ofensiva cross-tenant;
- T13 analyze/tests Flutter;
- T15 builds/smoke;
- T18 doble ejecución + restore;
- T19 decisión final.

Por tanto, la implementación del roadmap puede quedar cerrada sin declarar StOmni comercialmente verde.

## 10. Criterio de cierre de F9.6

F9.6 puede marcarse `[x]` a nivel de implementación cuando:

- runbook está versionado;
- template T19 está versionado y pendiente;
- gate de readiness tiene self-test;
- T02/T19 incorporan el gate/template;
- checklist registra la fase;
- Gate Bloque 9 sigue abierto;
- estado global comercial sigue abierto.

## 11. Resultado

Con F9.6 implementada, **todas las fases de implementación del roadmap SaaS quedan preparadas** y el siguiente trabajo ya no es agregar funcionalidades del roadmap: es ejecutar rigurosamente el mapa T00–T19 en local, corregir cualquier fallo encontrado y sólo entonces decidir `GO` o `NO-GO`.

El **GATE BLOQUE 9 VERDE permanece abierto** y StOmni **no se declara todavía listo para comercialización SaaS**.
