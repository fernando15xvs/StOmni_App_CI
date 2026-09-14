# Fase 2.4 — Edge Functions tenant-aware

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

La auditoría cubre las 21 Edge Functions versionadas/desplegadas del proyecto. Todas conservan `verify_jwt = true`. El cierre dinámico adversarial permanece en T10/T14 y en el Gate del Bloque 2.

## Contrato de autenticación y tenant

Las Edge Functions no aceptan `organization_id` como autoridad del cliente.

`_shared/auth_guard.ts` resuelve:

1. JWT de la sesión;
2. usuario autenticado;
3. membresía activa en `app_users`;
4. organización activa;
5. empleado activo correspondiente;
6. rol/base role requerido.

El contexto resultante contiene el `organizationId` resuelto por backend.

Cuando una Edge Function usa `service_role`, sus consultas deben filtrar explícitamente por ese tenant o delegar a RPC internos que exijan el header `x-stomni-organization-id` inyectado por el cliente administrativo creado por `auth_guard`.

## Superficie fiscal

Los flujos de comprobantes, notas de crédito, GRE y procesos tributarios utilizan los contextos compartidos tenant-aware y realizan prechecks de recursos antes de invocar operaciones privilegiadas.

La auditoría detectó un caso especial en `resolver-resultado-incierto`: el RPC backend estaba cerrado a clientes pero todavía operaba con UUID global. Se corrigió con doble defensa:

- Edge: `assertTenantResource(...)` valida el documento solicitado contra el tenant resuelto;
- PostgreSQL: `resolver_resultado_incierto_v1` exige `private.require_service_organization_id()` y filtra todas las operaciones por organización.

## Administración de empleados

### `create_employee`

Fue corregida para que un alta con acceso:

- herede exclusivamente `context.employee.organizationId`;
- cree la identidad Auth;
- cree `app_users` en la misma organización;
- escriba `empleados.organization_id` explícitamente;
- enlace `app_user_id`/`auth_id` sin aceptar tenant desde el body;
- compense de forma fail-closed: una membresía incierta se deshabilita antes de intentar limpieza irreversible.

### `delete_employee`

Fue corregida para:

- cargar el empleado objetivo dentro del tenant actual;
- impedir self-delete;
- contar administradores activos únicamente dentro de la organización;
- comprobar historial con contexto tenant;
- deshabilitar primero la membresía `app_users`;
- eliminar la ficha/membresía/Auth sólo después de cortar el acceso operativo.

## Cache global de personas

`get-persona` mantiene `personas_cache` como cache global deliberada, conforme al contrato técnico definido en F0.2. No representa ownership empresarial de clientes/proveedores. La Edge Function exige una sesión válida de empleado antes de usar `service_role` y la clave administrativa nunca llega a Flutter.

La clasificación global no autoriza convertir otras tablas de negocio en globales por analogía.

## Gate global

`scripts/verify_saas_edge_functions.mjs` fija, entre otros, estos invariantes:

- inventario exacto de 21 funciones;
- `verify_jwt = true` en `supabase/config.toml`;
- uso de `requireEmployee`/`createUserContext`;
- tenant resuelto desde backend;
- prohibición de confiar en `organization_id` del request;
- cliente `service_role` con contexto tenant interno;
- empleados creados/eliminados dentro del tenant;
- reconciliación fiscal con precheck;
- funciones fiscales delegando sólo a helpers/RPC tenant-aware.

El gate Edge también forma parte de `verify_saas_rpc_surface.mjs`, de modo que una nueva RPC llamada desde Edge debe quedar clasificada por el cierre global de F2.3.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| 21 Edge Functions inventariadas | ✅ |
| `verify_jwt=true` en todas | ✅ |
| Tenant no confiado desde body/query/header cliente | ✅ |
| Contexto tenant resuelto server-side | ✅ |
| `service_role` no depende de RLS | ✅ Tratado explícitamente |
| RPC internos reciben tenant verificado | ✅ |
| `create_employee` crea membresía tenant | ✅ |
| `delete_employee` no cruza empresas | ✅ |
| Reconciliación fiscal con doble defensa | ✅ |
| Gate Edge versionado | ✅ |
| Gate ejecutado sobre commit candidato final | ⏳ T02 |
| Ataques Edge ORG_A/ORG_B | ⏳ T10/T14 |
| `supabase db reset` completo | ⏳ T03/T18 |

## Resultado

F2.4 queda cerrada a nivel de implementación. F2.5 y el Gate del Bloque 2 permanecen abiertos hasta ejecutar los ataques cross-tenant dinámicos sobre una base local limpia.
