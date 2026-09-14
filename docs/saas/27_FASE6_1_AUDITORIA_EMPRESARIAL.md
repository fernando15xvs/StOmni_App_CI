# Fase 6.1 — Auditoría empresarial

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908050000_saas_enterprise_audit_logs.sql`
- `supabase/migrations/20260908050100_saas_enterprise_audit_safety.sql`

Gate:

- `scripts/verify_saas_enterprise_audit.mjs`

pgTAP:

- `supabase/tests/database/enterprise_audit_contract_test.sql` — 28 assertions.

Core Logic:

- `packages/core_logic/lib/audit/domain/audit_log_entry.dart`
- `packages/core_logic/lib/audit/application/audit_log_gateway.dart`
- `packages/core_logic/lib/audit/data/supabase_audit_log_gateway.dart`
- `packages/core_logic/lib/audit/providers/audit_log_providers.dart`

## Objetivo

F6.1 añade un ledger transversal para responder de forma consistente:

- qué acción crítica ocurrió;
- en qué empresa;
- quién la ejecutó;
- qué entidad afectó;
- cuándo ocurrió;
- qué metadata mínima es necesaria para investigar el evento.

No reemplaza los ledgers especializados ya existentes. Kardex, anulaciones, intentos fiscales y conciliaciones conservan sus propias fuentes históricas. `audit_logs` agrega una vista empresarial común sobre acciones sensibles sin duplicar todos los datos operativos.

## Modelo append-only

`public.audit_logs` contiene:

- `organization_id` obligatorio;
- timestamp autoritativo `occurred_at`;
- snapshots de actor (`actor_user_id`, empleado, etiqueta y rol);
- código de acción;
- tipo/ID de entidad;
- tabla y operación origen;
- `request_id` cuando existe;
- `metadata` JSONB segura.

La metadata debe ser un objeto y está limitada a 32 KiB. El diseño no admite payloads arbitrariamente grandes.

Un trigger `BEFORE UPDATE OR DELETE` rechaza mutaciones con `audit_logs is append-only`. Además, `authenticated` no recibe SELECT/INSERT/UPDATE/DELETE directo sobre la tabla.

## Aislamiento tenant

`private.write_audit_log()` valida que, cuando existe `auth.uid()`, el tenant de sesión coincida con `p_organization_id`. Un evento cross-tenant aborta.

El actor laboral se busca exclusivamente dentro de la organización del evento y soporta tanto el vínculo canónico `app_user_id` como `auth_id` mientras siga existiendo la transición legacy.

Cuando no existe `auth.uid()` el actor se marca como `system`. No se usa `current_user` como identidad humana porque la función es `SECURITY DEFINER` y ese valor representa al owner efectivo de la función, no al usuario de negocio.

## Metadata segura

`private.audit_pick_fields()` extrae sólo campos expresamente allowlisted. Los triggers genéricos reciben la allowlist como argumento.

No se persiste `to_jsonb(NEW)` o `to_jsonb(OLD)` como metadata completa. Esos objetos sólo se utilizan internamente para seleccionar campos.

Para `configuracion_negocio` se adopta una política aún más conservadora: el log guarda únicamente `changed_fields`, no los valores. Esto evita copiar accidentalmente certificados, tokens, secretos u otra configuración sensible que pueda incorporarse en el futuro.

El gate rechaza explícitamente patrones que intenten introducir passwords, tokens, secrets, certificados, private keys o access/refresh tokens en `jsonb_build_object` de auditoría.

## Cobertura inicial

El roadmap pide seis familias y todas quedan conectadas:

### Precios

- cambio de `precio_unidad`, `precio_caja`, `precio_compra` de productos;
- altas/cambios/bajas de `sale_price_rules`.

### Ajustes de stock

Se escucha `inventario_movimientos`, pero no se duplica el kardex entero. Sólo se registran movimientos clasificables como:

- merma;
- ajuste;
- corrección.

Ventas, recepciones y traslados ordinarios permanecen únicamente en su ledger de inventario.

### Anulaciones

`ventas_requests_anulados` genera `sale.cancelled`. El identificador semántico es `venta_id_original`; el snapshot fiscal/operativo completo que esa tabla ya guarda no se vuelve a copiar en `audit_logs`.

### Descuentos sensibles

`ventas` genera evento cuando existe descuento global positivo. Se conservan monto/porcentaje, autorizador, motivo acotado, subtotal bruto y total.

### Permisos

Se auditan:

- `role_permissions`;
- `employee_roles`;
- `employee_permission_overrides`.

### Configuración

Se auditan:

- `business_capabilities`;
- `custom_field_definitions`;
- cambios allowlisted de `configuracion_negocio`.

## Lectura

`list_audit_logs_v1()` es el único contrato de lectura para la app.

Características:

- tenant derivado server-side;
- permiso `tenant.admin` obligatorio;
- paginación por cursor `before_id`;
- página entre 1 y 200 filas;
- filtros opcionales por acción y entidad;
- orden descendente por ID.

Core Logic expone `AuditLogEntry`, `AuditLogPage` y `AuditLogGateway`. `SupabaseAuditLogGateway` usa exclusivamente el RPC literal `list_audit_logs_v1`; no accede directamente a `audit_logs`.

## Gate

`verify_saas_enterprise_audit.mjs` verifica:

- ownership tenant y RLS;
- ausencia de grants directos;
- append-only;
- metadata limitada;
- writer privado y bloqueo cross-tenant;
- actor tenant-aware;
- cobertura de las seis familias críticas;
- lectura RPC tenant/admin;
- cursor/paginación;
- contrato Dart;
- ausencia de filas completas en metadata;
- ausencia de campos sensibles.

Su self-test introduce regresiones artificiales (mutabilidad, pérdida de filtro tenant, payload completo, token en metadata y RPC no literal) y exige que todas sean detectadas.

## Validación dinámica pendiente

T03/T04/T07/T09/T12/T13 deberán demostrar, entre otros:

- migración limpia desde cero;
- ORG_A no puede listar eventos de ORG_B;
- actor no-admin no puede consultar auditoría;
- authenticated no puede insertar/modificar/borrar `audit_logs` directamente;
- UPDATE/DELETE privilegiado sobre el ledger falla por append-only;
- cambiar precio crea exactamente el evento esperado dentro del tenant;
- una merma genera auditoría y una venta ordinaria no duplica todo el kardex;
- anulación registra `venta_id_original` y motivo sin copiar el snapshot completo;
- cambio de permisos queda trazado;
- cambio de configuración no filtra secretos;
- gateway Dart decodifica y pagina correctamente.

## Resultado

F6.1 queda cerrada a nivel de implementación. StOmni dispone de un ledger empresarial transversal, tenant-aware, append-only y con metadata mínima segura para acciones críticas.
