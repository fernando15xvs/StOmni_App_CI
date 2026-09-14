# Fase 4.1 — Sucursales

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migración principal:

- `supabase/migrations/20260908030000_saas_branches.sql`

Gate específico:

- `scripts/verify_saas_branches.mjs`

Prueba pgTAP:

- `supabase/tests/database/branches_tenant_contract_test.sql` — 16 assertions.

## Objetivo

Crear la entidad `branches` como subdivisión operativa de una empresa sin adelantar relaciones de fases posteriores. En F4.1 una sucursal pertenece a una organización; almacenes, cajas y empleados se enlazarán respectivamente en F4.2, F4.3 y F4.4.

## Modelo implementado

`public.branches` contiene:

- `id uuid` opaco;
- `organization_id uuid NOT NULL`;
- `code` estable dentro de la empresa;
- `name`;
- `address` opcional;
- `is_main`;
- `status` (`active` / `inactive`);
- timestamps.

### Integridad tenant

Se añadieron:

- FK `organization_id -> organizations(id)` con `ON DELETE RESTRICT`;
- `UNIQUE (organization_id, id)` para preparar FKs compuestas de F4.2–F4.4;
- código único por organización;
- índice tenant/status;
- máximo una sucursal principal por organización mediante índice parcial único.

El `organization_id` y el UUID de una sucursal son inmutables.

### Sucursal principal

Toda organización debe comenzar con una sucursal utilizable:

- las organizaciones existentes reciben `MAIN / Principal` mediante backfill idempotente;
- un trigger `AFTER INSERT` sobre `organizations` crea la misma sucursal para tenants futuros dentro de la propia transacción de bootstrap.

La sucursal principal no puede quedar inactiva. `set_main_branch_v1` permite transferir la condición principal únicamente hacia otra sucursal activa del mismo tenant.

## Seguridad

### Data API

`branches` tiene RLS habilitado.

`authenticated` recibe sólo `SELECT`; no tiene `INSERT`, `UPDATE` ni `DELETE` directos.

La policy `branches_tenant_select` exige:

- `private.row_belongs_to_current_organization(organization_id)`;
- `private.has_permission('tenant.read')`.

### RPC

Las mutaciones disponibles son:

- `create_branch_v1(text,text,text)`;
- `update_branch_v1(uuid,text,text,text)`;
- `set_main_branch_v1(uuid)`.

Todas:

- derivan `organization_id` mediante `private.require_current_organization_id()`;
- requieren `private.has_permission('tenant.admin')`;
- nunca reciben `organization_id` desde Flutter;
- filtran el recurso objetivo por `(organization_id, id)`.

No se incorpora RPC de borrado físico. Una sucursal operativa se desactiva para preservar futura integridad histórica.

## Lo que deliberadamente NO hace F4.1

- no añade `branch_id` a `almacenes` — F4.2;
- no crea `cash_registers` ni enlaza `sesiones_caja` — F4.3;
- no añade sucursal principal a `empleados` — F4.4;
- no modifica el modelo de roles configurables — F4.5;
- no cambia la UI todavía;
- no aplica DDL al proyecto Supabase remoto.

## Gates

`verify_saas_branches.mjs` bloquea regresiones como:

- branch sin ownership tenant;
- ausencia de FK/clave compuesta;
- código global en vez de tenant-scoped;
- más de una sucursal principal;
- RLS ausente;
- escritura Data API directa para authenticated;
- RPC aceptando tenant del cliente;
- mutaciones sin `tenant.admin`;
- creación de tenant sin sucursal principal.

`branches_tenant_contract_test.sql` valida en PostgreSQL estructura, RLS, privileges, RPC allowlist, trigger de bootstrap y unicidad de sucursal principal.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| `branches` pertenece a `organizations` | ✅ |
| UUID + clave compuesta tenant para relaciones futuras | ✅ |
| código único por empresa | ✅ |
| máximo una principal por empresa | ✅ |
| tenant nuevo obtiene branch principal | ✅ |
| organizaciones existentes reciben principal | ✅ Migración idempotente |
| lectura RLS tenant-aware | ✅ |
| escritura directa cliente bloqueada | ✅ |
| creación/edición/main sólo mediante RPC admin | ✅ |
| RPC ignoran tenant manipulable | ✅ |
| gate estático versionado | ✅ |
| pgTAP 16 assertions versionado | ✅ |
| `supabase db reset` + pgTAP ejecutados | ⏳ Validación final local |
| ataque ORG_A/ORG_B sobre branch/RPC | ⏳ T07/T09/T14 |

## Resultado

F4.1 queda cerrada a nivel de implementación. La siguiente fase autorizada es F4.2 — Almacenes por sucursal. El Gate del Bloque 4 permanecerá abierto hasta completar F4.1–F4.5 y ejecutar sus escenarios multiempresa/multisucursal.
