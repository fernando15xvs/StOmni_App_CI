# Fase 2.3 — RPC tenant-aware

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

La fase se cierra a nivel de diseño, migraciones y gates estáticos después de completar el rollout F3.1–F3.7. El cierre dinámico cross-tenant permanece en T09/T12 y en el Gate del Bloque 2.

## Principio de seguridad

Ningún RPC operativo puede confiar en un `organization_id` enviado por Flutter. Los entrypoints cliente derivan la organización desde la sesión autenticada mediante `private.require_current_organization_id()` o helpers equivalentes.

Los RPC internos invocados por Edge Functions con `service_role` no dependen de RLS. Esos entrypoints:

- no tienen `EXECUTE` para `PUBLIC`, `anon` ni `authenticated`;
- reciben contexto de tenant sólo desde el header interno `x-stomni-organization-id` creado por el backend después de autenticar al usuario;
- validan dicho contexto en PostgreSQL mediante `private.require_service_organization_id()`.

## Cobertura por dominio

Los gates de F3.1–F3.7 cubren configuración, catálogos, inventario, ventas, compras y fiscal. La auditoría global añade superficies transversales que no pertenecían a un único CRUD.

### Dashboard

`20260908024900_saas_dashboard_summary_tenant.sql` redefine `get_dashboard_summary` para:

- derivar `v_org` server-side;
- filtrar productos, inventario, ventas, gastos y pagos por `organization_id`;
- preservar el contrato JSON esperado por Flutter;
- no consultar `movimientos`, porque Caja se tenantifica recién en F4.3.

### Permisos de empleados

`20260908025000_saas_employee_permissions_tenant.sql`:

- añade `organization_id` a `employee_permission_overrides`;
- usa FK compuesta `(organization_id, employee_id)`;
- namespacea la PK por organización;
- redefine las RPC de permisos para usar `app_users` y el tenant actual;
- impide consultar/modificar permisos de un empleado perteneciente a otra organización;
- conserva temporalmente el modelo de overrides hasta F4.5.

### Reconciliación fiscal

`20260908024800_saas_fiscal_reconciliation_scope.sql` corrigió un bypass detectado durante la auditoría: `resolver_resultado_incierto_v1` era service-role-only, pero operaba por UUID global recibido desde Edge.

Ahora:

- exige tenant interno verificado;
- valida al administrador dentro de ese tenant;
- todos los documentos y updates se filtran por organización;
- la reconciliación persiste `organization_id`;
- el Edge realiza además un precheck del recurso.

### Superficies deliberadamente diferidas

Caja y pago mixto de empleados pertenecen a F4.3/F4.4. No se consideran seguras por omisión: quedaron explícitamente fail-closed en `20260908025100_saas_deferred_operational_rpc_fail_closed.sql`.

- `get_estado_caja_chica()` no consulta tablas globales y devuelve Caja cerrada hasta F4.3;
- `registrar_pago_empleado_mixto(...)` perdió `EXECUTE` cliente;
- `core_logic` dejó de invocar esa RPC y devuelve un error funcional hasta que se complete F4.3/F4.4.

## Gate global

`scripts/verify_saas_rpc_surface.mjs`:

- ejecuta los gates de cada dominio;
- ejecuta `verify_saas_rpc_transversal.mjs`;
- escanea `apps/`, `packages/` y `supabase/functions/`;
- rechaza nombres RPC dinámicos/no literales;
- rechaza RPC no clasificados;
- rechaza `organization_id`/`p_organization_id` enviado por el llamador;
- bloquea entrypoints legacy o diferidos;
- verifica contratos `service_role` internos.

`scripts/verify_saas_rpc_transversal.mjs` fija los invariantes de dashboard, permisos y superficies diferidas.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| RPC F3.1–F3.7 tenant-aware | ✅ |
| Tenant derivado server-side en entrypoints cliente | ✅ |
| RPC internos service-role cerrados a clientes | ✅ |
| Tenant interno Edge -> PostgreSQL verificado | ✅ |
| Dashboard no mezcla empresas | ✅ Implementado |
| Permisos de empleados no cruzan tenants | ✅ Implementado |
| Reconciliación fiscal no acepta UUID ajeno | ✅ Implementado |
| Caja/pagos de empleados diferidos fail-closed | ✅ |
| Scanner global de RPC versionado | ✅ |
| RPC dinámicos críticos eliminados del runtime | ✅ |
| Gate global ejecutado sobre commit candidato final | ⏳ T02 |
| Ataque real ORG_A/ORG_B a RPC | ⏳ T09/T12 |
| `supabase db reset` completo | ⏳ T03/T18 |

## Resultado

F2.3 queda cerrada a nivel de implementación. No se declara todavía el Gate del Bloque 2: falta ejecutar la matriz adversarial ORG_A/ORG_B y la reconstrucción local completa sobre el commit candidato final.
