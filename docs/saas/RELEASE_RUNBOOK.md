# StOmni SaaS — Release Runbook

## Estado

**PROCESO VERSIONADO / EJECUCIÓN DE RELEASE NO AUTORIZADA HASTA T19=GO**

Este runbook define el procedimiento técnico de salida comercial. No constituye autorización de despliegue y no reemplaza `docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md`.

## 1. Condición de entrada

Un release SaaS sólo puede iniciarse cuando existe:

```text
docs/saas/FINAL_VALIDATION_REPORT.md
```

con decisión explícita `GO` y evidencia de T00–T19 ejecutada sobre el mismo commit candidato.

Si el informe no existe, contiene `NO-GO`, tiene pruebas críticas omitidas/fallidas o pertenece a otro commit, el release se detiene.

## 2. Freeze del candidato

Registrar antes de cualquier cambio remoto:

- rama candidata;
- commit SHA exacto;
- árbol limpio;
- tag/version prevista;
- plataformas que realmente fueron validadas en T15;
- versión de Supabase CLI/PostgreSQL usada en T03/T18;
- artefactos de build correspondientes al commit.

No reconstruir artefactos desde un commit distinto después del GO sin repetir la validación afectada.

## 3. Pre-release de backend

Antes de aplicar cambios al entorno comercial:

1. confirmar proyecto/entorno destino;
2. confirmar que ninguna variable apunta accidentalmente al laboratorio;
3. confirmar secretos únicamente en el gestor del proveedor, nunca en Flutter ni Git;
4. confirmar backup previo y política de recuperación aplicable;
5. registrar estado/migración actual del destino;
6. comprobar que el commit candidato contiene exactamente las migraciones aprobadas;
7. verificar que Edge Functions y configuración esperada pertenecen al mismo candidato.

Nunca usar datos reales de clientes para completar tests faltantes del roadmap.

## 4. Orden de despliegue

El orden general es:

1. congelar/registrar commit candidato;
2. tomar backup pre-release según la política vigente;
3. aplicar migraciones de base de datos aprobadas;
4. desplegar Edge Functions/configuración backend aprobadas;
5. verificar health/smoke del backend;
6. publicar clientes sólo de plataformas declaradas verdes en T15;
7. ejecutar smoke post-release;
8. observar errores, latencia y jobs mediante F9.4;
9. documentar resultado del release.

No ejecutar pasos posteriores si una migración o smoke crítico falla.

## 5. Migraciones

Reglas:

- aplicar sólo migraciones versionadas del commit GO;
- no editar producción desde Studio para “arreglar” el release;
- no desactivar RLS, constraints o triggers para hacer avanzar el despliegue;
- registrar migraciones aplicadas y timestamps;
- cualquier corrección debe convertirse en código/migración versionada y pasar por validación antes de reintentar.

## 6. Edge Functions y secretos

- `service_role`, secretos cron, tokens fiscales/proveedor y credenciales privadas viven sólo en backend;
- ninguna clave privilegiada se copia a `.env` de Flutter/Web;
- Edge Functions desplegadas deben corresponder al mismo commit GO;
- cambios de secretos/configuración deben registrarse sin registrar su valor;
- rotación de secretos no debe requerir recompilar el cliente salvo credenciales públicas/publishable.

## 7. Storage

Antes del release confirmar:

- policies tenant-aware;
- buckets sensibles privados;
- paths nuevos bajo `<organization_id>/...`;
- signing/listado/lectura probados en T11;
- backup/restore de objetos validado en T18.

## 8. Clientes y plataformas

Sólo se declara soporte comercial para una plataforma cuya casilla de T15 esté verde en el informe final.

Un build no ejecutado por limitaciones del host no puede declararse soportado por inferencia. Por ejemplo, iOS/macOS requieren validación en macOS.

## 9. Billing

La arquitectura F7 es provider-agnostic. Antes de habilitar cobros reales debe existir una decisión explícita del proveedor y deben estar configurados/probados sus identificadores, webhooks e idempotencia en el entorno correspondiente.

Si aún no existe proveedor comercial configurado, el release no debe simular pagos reales ni inventar price IDs. La monetización debe mantenerse deshabilitada o en el modo explícitamente aprobado hasta completar esa integración.

## 10. Backup, RPO y RTO

Antes de un GO comercial deben quedar registrados en T19:

- política de retención realmente disponible;
- RPO aprobado según capacidades reales del proveedor/plan;
- RTO medido o aprobado con evidencia;
- resultado del restore drill T18;
- ubicación/protección de backups.

No convertir objetivos no medidos en promesas contractuales.

## 11. Smoke post-release

Con datos controlados y sin cruzar tenants, verificar como mínimo:

- login;
- resolución de tenant;
- lectura de configuración/branding;
- operación de negocio no destructiva representativa;
- Edge crítica;
- Storage tenant-safe;
- observabilidad `trace_id`;
- ausencia de error crítico/release blocker.

No usar `service_role` para simular un cliente.

## 12. Criterios de abortar

Abortar o detener el rollout ante:

- fuga cross-tenant;
- `TENANT_ISOLATION_VIOLATION`;
- `PII_SECRET_LOG_EXPOSURE`;
- migración fallida;
- pérdida/corrupción de datos;
- autenticación/autorización rota;
- Storage cross-tenant accesible;
- operación administrativa global accesible al cliente;
- error crítico en venta/inventario/fiscal/caja;
- restauración requerida pero no viable;
- artefactos que no corresponden al commit GO.

## 13. Rollback / recuperación

El rollback depende del tipo de fallo:

- cliente: detener rollout/revertir artefacto compatible;
- Edge/config: volver a versión/config aprobada cuando sea seguro;
- DB: no intentar “deshacer” migraciones destructivas a ciegas; seguir la estrategia documentada para la migración y la política de backup/restore;
- datos: usar el procedimiento F9.3 correspondiente y registrar toda restauración.

Cualquier rollback que cambie código o esquema genera un nuevo candidato y requiere revalidar la superficie afectada antes de un nuevo GO.

## 14. Observación posterior

Después del release revisar:

- tasa de `failed`;
- p95/p99 frente al baseline aprobado;
- `denied` anómalos;
- `BATCH_PARTIAL_FAILURE`;
- fallos de persistencia de observabilidad;
- errores funcionales críticos;
- métricas por tenant sin exposición cross-tenant.

Los umbrales operativos usados deben ser los aprobados en T19, no valores inventados durante el incidente.

## 15. Evidencia del release

Conservar:

- commit/tag desplegado;
- fecha/hora;
- entorno;
- migraciones aplicadas;
- Edge Functions desplegadas;
- plataformas/artefactos publicados;
- smoke post-release;
- incidencias/rollback si existieron;
- enlace/referencia al `FINAL_VALIDATION_REPORT.md` usado para autorizar la salida.

## 16. Regla final

**Implementar este runbook no equivale a ejecutar un release.**

La única autorización técnica de salida del roadmap es un `FINAL_VALIDATION_REPORT.md` del mismo commit con T00–T19 completos, cero pruebas críticas fallidas, cero pruebas críticas omitidas y decisión `GO`.
