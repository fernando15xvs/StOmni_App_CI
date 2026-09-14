# StOmni SaaS — Final Validation Report Template

> Copiar esta plantilla a `docs/saas/FINAL_VALIDATION_REPORT.md` únicamente durante T19. No completar `GO` por inferencia ni por revisión estática.

## 1. Candidato

- Fecha/hora:
- Rama:
- Commit SHA:
- Árbol limpio antes de ejecutar: PENDIENTE
- Operador/entorno de prueba:

## 2. Toolchain

| Herramienta | Versión | Evidencia |
|---|---|---|
| Flutter | PENDIENTE | |
| Dart | PENDIENTE | |
| Node | PENDIENTE | |
| Supabase CLI | PENDIENTE | |
| PostgreSQL / psql | PENDIENTE | |
| pg_dump | PENDIENTE | |
| pg_restore | PENDIENTE | |
| Docker | PENDIENTE | |

## 3. Resultado T00–T19

| Bloque | Estado | Exit code / evidencia | Observaciones |
|---|---|---|---|
| T00 | PENDIENTE | | |
| T01 | PENDIENTE | | |
| T02 | PENDIENTE | | |
| T03 | PENDIENTE | | |
| T04 | PENDIENTE | | |
| T05 | PENDIENTE | | |
| T06 | PENDIENTE | | |
| T07 | PENDIENTE | | |
| T08 | PENDIENTE | | |
| T09 | PENDIENTE | | |
| T10 | PENDIENTE | | |
| T11 | PENDIENTE | | |
| T12 | PENDIENTE | | |
| T13 | PENDIENTE | | |
| T14 | PENDIENTE | | |
| T15 | PENDIENTE | | |
| T16 | PENDIENTE | | |
| T17 | PENDIENTE | | |
| T18 | PENDIENTE | | |
| T19 | PENDIENTE | | |

## 4. Conteo de pruebas

- Passed: PENDIENTE
- Failed: PENDIENTE
- Skipped/omitidas: PENDIENTE
- Pruebas críticas fallidas: PENDIENTE
- Pruebas críticas omitidas: PENDIENTE

## 5. Flutter

### Analyze

- `core_logic`: PENDIENTE
- `mobile_app`: PENDIENTE
- `desktop_app`: PENDIENTE
- raíz, si aplica: PENDIENTE

### Tests

- `core_logic`: PENDIENTE
- `mobile_app`: PENDIENTE
- `desktop_app`: PENDIENTE

## 6. Supabase / DB

- Primer `supabase db reset`: PENDIENTE
- Segundo `supabase db reset`: PENDIENTE
- pgTAP total: PENDIENTE
- `observability_contract_test.sql`: PENDIENTE
- `final_security_contract_test.sql`: PENDIENTE
- Drift/manual fixes: PENDIENTE

## 7. Matriz multi-tenant

- ORG_A -> ORG_B lectura: PENDIENTE
- ORG_A -> ORG_B escritura: PENDIENTE
- ORG_B -> ORG_A lectura: PENDIENTE
- ORG_B -> ORG_A escritura: PENDIENTE
- RPC cross-tenant: PENDIENTE
- Edge/service_role cross-tenant: PENDIENTE
- Storage cross-tenant: PENDIENTE

## 8. E2E y dominio

- Runner F9.1: PENDIENTE
- Ventas/inventario/caja: PENDIENTE
- Compras/proveedores: PENDIENTE
- Fiscal/GRE: PENDIENTE
- Onboarding/branding/cache: PENDIENTE
- Estados disabled/suspended/closed: PENDIENTE

## 9. Builds y plataformas

| Plataforma | Build | Smoke | Soporte comercial autorizado |
|---|---|---|---|
| Web | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |
| Android | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |
| Windows | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |
| iOS | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |
| macOS | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |
| Linux | PENDIENTE | PENDIENTE | NO HASTA VALIDAR |

## 10. Performance F9.2

- Hardware/fixture:
- Concurrency:
- p50:
- p95:
- p99:
- Idempotencia exactly-once: PENDIENTE
- Independencia ORG_A/ORG_B: PENDIENTE
- Planes/índices revisados: PENDIENTE

## 11. Backup y recuperación F9.3

- Backup candidato: PENDIENTE
- Restore drill T18: PENDIENTE
- Estado `f9_3_restore_report.json`: PENDIENTE
- Fingerprints DB exactos: PENDIENTE
- SHA-256 Storage exactos: PENDIENTE
- Tiempo real de restore: PENDIENTE
- Export tenant A/B: PENDIENTE
- RPO aprobado: PENDIENTE
- RTO aprobado: PENDIENTE
- Retención aprobada: PENDIENTE

## 12. Observabilidad F9.4

- T02 gate: PENDIENTE
- T04 contrato DB: PENDIENTE
- Trace A/B aislado: PENDIENTE
- Job IDs: PENDIENTE
- 401/403 `denied`: PENDIENTE
- `BATCH_PARTIAL_FAILURE`: PENDIENTE
- p50/p95/p99 observabilidad: PENDIENTE
- failed/denied counts: PENDIENTE
- revisión PII/secrets: PENDIENTE
- `TENANT_ISOLATION_VIOLATION`: PENDIENTE
- `PII_SECRET_LOG_EXPOSURE`: PENDIENTE
- umbrales operativos aprobados: PENDIENTE

## 13. Seguridad F9.5

- Gate estático T02: PENDIENTE
- Contrato DB T04: PENDIENTE
- archivos sensibles versionados: PENDIENTE
- secretos/backend admin API en Flutter: PENDIENTE
- T07 aislamiento: PENDIENTE
- T10 Edge/service_role: PENDIENTE
- T11 Storage: PENDIENTE
- T16 hardening adversarial: PENDIENTE

## 14. Release F9.6

- Runbook revisado: PENDIENTE
- commit candidato congelado: PENDIENTE
- plataformas a publicar derivadas de T15: PENDIENTE
- estrategia de backup/rollback confirmada: PENDIENTE
- billing real habilitado sólo si proveedor/config fue aprobado y probado: PENDIENTE
- secretos de producción fuera del repositorio/cliente: PENDIENTE

## 15. Defectos y desviaciones

| ID | Severidad | Hallazgo | Corrección/decisión | Commit |
|---|---|---|---|---|
| | | | | |

## 16. Release blockers

- fuga cross-tenant: PENDIENTE
- corrupción/pérdida de datos: PENDIENTE
- fallo crítico de Auth/RLS/RPC/Edge/Storage: PENDIENTE
- PII/secreto expuesto: PENDIENTE
- restore no viable: PENDIENTE
- prueba crítica fallida: PENDIENTE
- prueba crítica omitida: PENDIENTE

## 17. Decisión

**DECISIÓN: PENDIENTE**

Valores permitidos al cerrar T19:

```text
GO
NO-GO
```

`GO` sólo es válido con T00–T19 completos, cero pruebas críticas fallidas, cero pruebas críticas omitidas y sin release blockers abiertos.

## 18. Evidencias / referencias

- Logs:
- Reportes `.dart_tool/saas/`:
- Capturas/smoke:
- Commits de corrección:
- Otras evidencias:
