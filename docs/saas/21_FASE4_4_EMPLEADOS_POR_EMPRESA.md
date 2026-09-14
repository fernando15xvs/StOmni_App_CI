# Fase 4.4 — Empleados por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones relevantes:

- `supabase/migrations/20260907022207_saas_employees_identity_separation.sql`
- `supabase/migrations/20260908035000_saas_employees_professional_structure.sql`
- `supabase/migrations/20260908035100_saas_employee_payments_contract.sql`

Gate:

- `scripts/verify_saas_employees_structure.mjs`

Contrato pgTAP:

- `supabase/tests/database/employees_structure_contract_test.sql`

No se aplicó DDL al proyecto Supabase remoto. La ejecución final queda reservada para T00–T19 en local.

## Contrato laboral

F1.3 ya separó correctamente la ficha `empleados` de la identidad de acceso:

- `organization_id` define el tenant del empleado;
- `app_user_id` es opcional;
- un empleado puede existir sin login;
- el enlace con `app_users` es tenant-qualified.

F4.4 conserva ese diseño y lo completa con:

- `branch_id NOT NULL` como sucursal principal;
- `employment_status NOT NULL` con estados `active`, `inactive`, `leave`, `terminated`;
- `cargo`, nombre, teléfono y email existentes como parte de la ficha laboral;
- `activo` mantenido por compatibilidad y sincronizado con el estado laboral.

## Sucursal principal

Los empleados históricos se asignan a la sucursal principal de su tenant. Después del backfill, `branch_id` queda obligatorio y protegido por FK compuesta:

```text
(organization_id, branch_id)
  -> branches(organization_id, id)
```

Un empleado de ORG_A no puede quedar ligado a una sucursal de ORG_B.

El trigger `private.enforce_employee_branch_status()`:

- impide cambiar de organización;
- asigna la sucursal principal cuando el insert no trae `branch_id`;
- exige que la sucursal esté activa dentro del mismo tenant;
- mantiene compatibilidad entre `activo` y `employment_status`.

## Acceso opcional

F4.4 no vuelve a unir conceptualmente empleado y usuario. `app_user_id` continúa nullable.

Esto permite:

- empleado sin cuenta;
- empleado con acceso explícitamente vinculado;
- desactivar/terminar una relación laboral sin convertir la tabla laboral en proveedor de autenticación.

## Pagos de empleados

`pagos_empleados` recibe:

- `organization_id NOT NULL`;
- `cash_register_id`;
- `cash_session_id`;
- `empleado_id NOT NULL`.

Las relaciones empleado y Caja son tenant-qualified. La tabla queda con RLS de lectura para `tenant.admin` y sin escritura directa desde Data API.

## RPC de pagos de personal

`registrar_pago_empleado_mixto` fue reemplazada por una implementación tenant-aware.

La nueva versión:

1. exige `tenant.admin`;
2. valida el empleado dentro del tenant actual;
3. rechaza empleado terminado;
4. valida payload y montos;
5. si el pago efectivo afecta Caja, exige la sesión abierta del usuario;
6. calcula saldo sólo por `cash_session_id`;
7. rechaza saldo insuficiente;
8. inserta `organization_id` y `cash_session_id` server-side.

La revocación transitoria introducida antes de F4.4 se sustituye por un `GRANT EXECUTE` explícito únicamente para `authenticated`.

## Caja completa

`private.cash_session_available_balance()` ahora incorpora:

- ingresos de `pagos_venta`;
- egresos de `pagos_gasto`;
- egresos de `pagos_empleados`;

todos filtrados por organización y `cash_session_id`.

`get_estado_caja_chica()` aplica la misma regla.

## Vistas financieras

`movimientos` y `reportes_movimientos_financieros` conservan `security_invoker=true` y reincorporan pagos de personal mediante joins tenant-qualified.

Con esto la exclusión temporal de pagos de empleados aplicada en F4.3 queda eliminada de forma segura.

## Gate estático

`verify_saas_employees_structure.mjs` verifica:

- separación identidad/empleado;
- branch y estado laboral;
- FK branch tenant-qualified;
- pagos de personal con ownership tenant;
- `empleado_id` obligatorio;
- RLS administrativo;
- RPC tenant/cash-aware;
- saldo de Caja incluyendo personal por sesión;
- vistas financieras con pagos de personal;
- ausencia de búsqueda de “última caja abierta” global.

## Contrato dinámico previsto

`employees_structure_contract_test.sql` contiene 20 assertions pgTAP.

T07/T09/T12 deberán probar además:

- empleado A no visible/mutable desde B;
- branch B no puede asignarse a empleado A;
- empleado sin `app_user_id` funciona como ficha laboral;
- `app_user_id` de ORG_B no puede enlazarse a empleado A;
- pago a empleado B es rechazado desde A;
- pago de personal A afecta sólo la sesión A;
- saldo insuficiente no inserta filas parciales;
- usuario no-admin no puede registrar pagos a personal.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| empleado pertenece a organización | ✅ |
| acceso opcional mediante `app_user_id` | ✅ |
| sucursal principal obligatoria | ✅ |
| estado laboral explícito | ✅ |
| pagos de personal tenant-aware | ✅ |
| pagos de personal cash-session-aware | ✅ |
| RLS administrativo de pagos | ✅ |
| RPC de pagos reabierta con seguridad | ✅ |
| Caja incluye egresos de personal por sesión | ✅ |
| vistas financieras completas y `security_invoker` | ✅ |
| gate estático versionado | ✅ |
| pgTAP versionado | ✅ |
| `supabase db reset` | ⏳ T03/T18 |
| ataques ORG_A/ORG_B | ⏳ T07/T09/T12 |

## Resultado

F4.4 queda cerrada a nivel de implementación. La ficha laboral ya tiene tenant, sucursal, estado y acceso opcional; pagos de personal dejan de ser una superficie global y pasan a compartir el mismo contrato de Caja por sesión implementado en F4.3.
