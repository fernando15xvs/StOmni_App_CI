# Fase 0.2 — Contrato técnico de tenant

Estado: **CERRADA / AUDITADA**  
Rama: `feature/saas-multitenant-foundation`

## Objetivo

Congelar las reglas técnicas de identidad, pertenencia, aislamiento y propagación de tenant antes de introducir `organizations`, `app_users` y `organization_id` en el esquema operativo.

Esta fase **no modifica la base de datos**. Define las invariantes que las Fases 1.x, 2.x y 3.x deberán implementar y probar.

---

## 1. Definición canónica de tenant

En StOmni, un tenant es una **organización/empresa independiente**.

Entidad raíz:

```text
public.organizations
```

Identificador canónico:

```text
organization_id UUID
```

Reglas:

1. `organizations.id` será un UUID generado por backend/base de datos.
2. El UUID es opaco: no codifica RUC, país, plan, sucursal ni ningún dato de negocio.
3. `organization_id` es inmutable durante la vida de una fila.
4. Los identificadores legacy como `configuracion_negocio.id = 1` dejan de representar identidad de empresa.
5. No se reutiliza un `organization_id` de una empresa cerrada para otra empresa.

### Esquema mínimo objetivo de `organizations`

La Fase 1.1 deberá materializar al menos este contrato lógico:

- `id uuid primary key`
- `legal_name text null`
- `display_name text not null`
- `country_code text not null` — ISO 3166-1 alpha-2
- `currency_code text not null` — ISO 4217
- `timezone text not null` — nombre IANA
- `status text not null` — `active | suspended | closed`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

Los valores regionales se definen al crear la empresa; el modelo no debe depender permanentemente de Perú/PEN/`America/Lima`.

---

## 2. Identidad: Auth, acceso a StOmni y empleado son conceptos distintos

El modelo objetivo separa tres capas:

```text
auth.users
    ↓ 1:1 en V1
public.app_users
    ↓ 0..1
public.empleados
```

### 2.1 `auth.users`

Supabase Auth sigue siendo la **única identidad de autenticación**.

- contraseñas, tokens y sesiones pertenecen a Supabase Auth;
- ninguna tabla `public` duplica contraseñas;
- `auth.uid()` identifica al usuario autenticado, pero **no identifica por sí solo el tenant**.

### 2.2 `app_users`

`app_users` será la relación autorizada entre una identidad Auth y StOmni.

Contrato mínimo objetivo:

- `user_id uuid primary key references auth.users(id)`
- `organization_id uuid not null references organizations(id)`
- `status text not null` — inicialmente `active | disabled`
- `base_role text not null` — compatibilidad V1: `admin | operador`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

Además deberá existir una clave apta para FKs compuestas:

```text
UNIQUE (organization_id, user_id)
```

### Invariante V1: una cuenta -> una empresa

Un `user_id` sólo puede tener una fila en `app_users`; por tanto, en V1 una identidad Auth pertenece a **exactamente una organización** cuando tiene acceso activo a StOmni.

No habrá selector de empresa en Flutter en V1.

Si en el futuro una misma identidad necesita acceso a varias empresas, se diseñará explícitamente un modelo de membresías. **No se simulará creando duplicados de Auth ni relajando este contrato de forma accidental.**

### 2.3 `empleados`

`public.empleados` seguirá siendo una entidad de dominio/laboral y podrá existir sin login.

Reglas objetivo:

- `organization_id uuid not null`;
- vínculo opcional a `app_users` mediante un identificador de usuario;
- el vínculo, cuando exista, debe pertenecer a la misma organización;
- un `app_user` no puede quedar vinculado simultáneamente a dos empleados;
- borrar/deshabilitar acceso no debe borrar automáticamente la ficha laboral;
- `empleados.auth_id` es deuda de transición y dejará de ser la fuente de verdad de autorización.

La relación objetivo deberá poder protegerse con FK compuesta equivalente a:

```text
(organization_id, app_user_id)
    -> app_users(organization_id, user_id)
```

El campo legacy `empleados.rol` podrá mantenerse temporalmente durante la migración, pero después de la separación de Fase 1.3 el rol de seguridad se resolverá desde `app_users` y, más adelante, desde el modelo configurable de roles/permisos del Bloque 4.

---

## 3. Resolución del tenant autenticado

La empresa activa **siempre se deriva en backend**.

Flujo canónico:

```text
JWT válido
  -> auth.uid()
  -> app_users.user_id
  -> app_users.organization_id
  -> organizations.id
```

Una operación interactiva sólo obtiene contexto tenant cuando:

- existe el usuario Auth;
- existe una fila `app_users` para ese `user_id`;
- `app_users.status = 'active'`;
- `organizations.status = 'active'`.

Una organización `suspended` o `closed` no puede ejecutar operaciones normales de negocio aunque el JWT siga siendo criptográficamente válido.

### Regla de confianza

Un `organization_id` enviado por Flutter, Web, Desktop, query string, JSON, header o parámetro RPC **nunca es autoridad**.

- RPC críticas deben resolver la empresa desde `auth.uid()`.
- RLS debe comparar la fila con el tenant resuelto en PostgreSQL.
- Edge Functions con `service_role` deben resolver primero el tenant del usuario y filtrar explícitamente todas las consultas/escrituras.
- Si una API necesita recibir `organization_id` por compatibilidad o routing, sólo puede tratarlo como dato a validar contra el tenant resuelto; nunca como fuente de verdad.

---

## 4. Helpers objetivo de autorización

El Bloque 2 deberá introducir helpers equivalentes a estos conceptos:

- `app_current_organization_id()` — tenant de `auth.uid()` o `NULL` si no tiene contexto activo;
- `app_user_active()` — usuario StOmni habilitado y organización activa;
- `app_base_role()` — rol base del `app_user` actual;
- `app_has_permission(code)` — permiso efectivo dentro del tenant;
- helper de pertenencia tenant para filas cuando simplifique policies.

Todos los helpers `SECURITY DEFINER` deberán fijar un `search_path` seguro y no aceptar un tenant manipulable por el cliente.

Los helpers actuales basados en `empleados.auth_id` (`app_empleado_activo`, `app_es_admin`, `_gre_empleado_activo`, `get_user_role`, `app_tiene_permiso`) son compatibilidad legacy y deberán migrarse hacia este contrato.

---

## 5. Regla de propagación de `organization_id`

Decisión: las tablas tenant-owned llevarán **`organization_id` directo**, incluso cuando pudiera inferirse desde un padre.

Motivos:

- RLS simple y auditable;
- índices por tenant;
- consultas y reportes sin joins de seguridad implícitos;
- idempotencia y auditoría por empresa;
- posibilidad de FKs compuestas que bloqueen relaciones cruzadas.

La clasificación de Fase 0.1 queda así:

- 55 tablas de negocio: tenant-scoped;
- 4 tablas internas transaccionales: tenant-scoped;
- `stock_alert_tx_context`: contexto efímero pero tenant-scoped;
- `gre_ubigeos`: global/read-only;
- `personas_cache`: global **interna de plataforma**, no dato de negocio de una empresa.

### Regla para `personas_cache`

`personas_cache` puede seguir siendo una caché global porque representa el resultado técnico de una consulta DNI/RUC y evita duplicar la misma respuesta por empresa, pero:

- no debe ser seleccionable directamente por clientes `anon/authenticated`;
- se accede sólo mediante backend autorizado;
- no puede almacenar preferencias, notas ni modificaciones tenant-specific;
- cualquier cliente/proveedor creado a partir de la consulta se copia a la tabla tenant-owned correspondiente;
- su retención y minimización de datos deberán revisarse como parte del hardening de privacidad.

---

## 6. Integridad referencial entre tablas tenant-owned

No basta con que dos tablas tengan `organization_id`; una FK simple por ID puede permitir enlazar accidentalmente una fila de Empresa A con un padre de Empresa B.

Regla objetivo para relaciones críticas:

```text
child (organization_id, parent_id)
  -> parent (organization_id, id)
```

Por ello las tablas padre deberán exponer, cuando sea necesario:

```text
UNIQUE (organization_id, id)
```

Esto aplica especialmente a:

- cabecera/detalle;
- venta/pago;
- compra/recepción;
- producto/inventario/lote/serial;
- almacén/movimientos;
- documentos fiscales y sus intentos/detalles;
- empleado/permisos;
- solicitudes idempotentes y su operación de negocio.

Principio: **una relación cross-tenant debe fallar por constraint incluso antes de depender de la UI**.

---

## 7. Unicidades de negocio

Los UUID técnicos (`request_id`, IDs de entidades cuando ya sean UUID) pueden seguir siendo globalmente únicos.

Las claves que representan identidad comercial u operativa se vuelven únicas **dentro de la empresa**, no globalmente.

Patrón:

```text
UNIQUE (organization_id, business_key...)
```

La revisión identificada en Fase 0.1 incluye como mínimo:

- `empleados.email`;
- `gre_conductores(tipo_documento, numero_documento)`;
- `gre_transportistas.ruc`;
- `gre_vehiculos.placa`;
- `constancias_descuento.codigo`;
- `comprobantes_electronicos(tipo_documento_sunat, serie, correlativo)`;
- `guias_remision(tipo_documento_sunat, serie, correlativo)`;
- `notas_credito(serie, correlativo)`;
- `procesos_tributarios.identificador`;
- `procesos_tributarios(tipo_proceso, fecha_referencia, correlativo)`;
- `series_comprobantes(tipo_documento_sunat, serie)`;
- SKU/códigos de producto cuando corresponda.

La normalización (`lower`, trim, formato de documento, etc.) se mantendrá consistente con la regla funcional de cada dominio.

---

## 8. Contrato de correo electrónico

Hay dos significados distintos de email.

### Email de Auth

- Es identidad de login gestionada por Supabase Auth.
- Su unicidad sigue siendo global dentro del proyecto Supabase.
- En V1, una misma identidad Auth no puede pertenecer a dos empresas.

### Email de empleado

- Es un dato de contacto de la ficha laboral.
- No es una identidad de autenticación.
- Su unicidad, si se exige, será por `organization_id` y no global.
- La misma dirección puede existir como dato de contacto en empleados de empresas distintas.

Si un empleado tiene acceso a StOmni, sólo puede vincularse al `app_user` cuya `organization_id` coincida.

Caso futuro "una persona con la misma cuenta accede a varias empresas": **fuera de alcance V1**; requerirá membresías multi-organización explícitas.

---

## 9. Configuración y capacidades dejan de ser la identidad del tenant

### `configuracion_negocio`

Deberá evolucionar a configuración 1:1 por organización:

```text
organization_id uuid not null unique references organizations(id)
```

Su PK bigint legacy puede conservarse durante la transición para reducir el radio de cambio, pero `id = 1` deja de tener semántica de empresa.

### `business_capabilities`

Deberá dejar de usar:

```text
business_id = 1
CHECK (business_id = 1)
```

y quedar relacionada directamente con la organización. El contrato preferido es una fila de capacidades por `organization_id`.

### `business_metric_definitions`

También se vuelve tenant-owned por `organization_id`; una definición/configuración editable por una empresa no puede contaminar otra.

---

## 10. RLS

Toda tabla tenant-owned expuesta a `authenticated` deberá aplicar aislamiento para las cuatro operaciones cuando correspondan:

- `SELECT`: sólo filas con `row.organization_id = app_current_organization_id()`;
- `INSERT`: `WITH CHECK` del tenant actual;
- `UPDATE`: `USING` + `WITH CHECK` para impedir mover una fila entre empresas;
- `DELETE`: sólo tenant actual y permiso correspondiente.

El cliente no puede cambiar `organization_id` de una fila existente.

Las policies de rol (`admin`, `operador`, permisos específicos) se aplican **después** de establecer pertenencia al tenant; nunca reemplazan el filtro de tenant.

---

## 11. RPC, triggers y vistas

### RPC

Una RPC crítica:

1. valida usuario activo;
2. resuelve `organization_id` desde Auth;
3. valida rol/permiso;
4. opera exclusivamente sobre ese tenant;
5. no confía en tenant recibido del cliente;
6. devuelve sólo filas del tenant.

### Triggers

Todo trigger que consulte tablas tenant-owned debe preservar `NEW.organization_id` y comprobar coherencia con filas relacionadas, preferentemente mediante constraints compuestas.

Un trigger no puede consultar una configuración global `id = 1`.

### Vistas

Las vistas tenant-owned deberán conservar `organization_id` en su semántica y no agregar datos de empresas distintas. Cuando sean accesibles por cliente, deben respetar RLS de forma verificable y no convertirse en bypass.

---

## 12. Edge Functions

El contexto actual:

```text
AuthorizedEmployeeContext
```

no es suficiente para SaaS porque sólo conoce `employee` y usa un cliente `service_role`.

Contrato objetivo: un contexto autorizado deberá incluir como mínimo:

- usuario Auth;
- `organizationId` resuelto desde `app_users`;
- rol/permisos de aplicación;
- empleado vinculado cuando la operación realmente requiera una ficha laboral;
- cliente admin sólo para las operaciones que lo necesiten.

Una Edge Function con `service_role` tiene la obligación explícita de añadir el filtro de `organization_id` a cada acceso tenant-owned.

### Procesos de sistema/cron

Los procesos sin usuario interactivo no reciben un tenant arbitrario desde Internet. Cuando deban operar varias empresas:

1. enumeran organizaciones autorizadas desde contexto de sistema;
2. procesan cada `organization_id` de forma explícita;
3. mantienen idempotencia y logs por tenant;
4. nunca ejecutan un UPDATE/DELETE tenant-owned sin scope.

---

## 13. Storage

Todo objeto tenant-owned usará rutas con prefijo canónico:

```text
<organization_id>/...
```

Reglas:

- escritura, reemplazo, borrado y listado validados por tenant;
- `comprobantes-electronicos` permanece privado y tenant-isolated;
- para el SaaS estricto, logos e imágenes de productos deberán ser privados por defecto o servirse mediante una capa explícita de publicación/autorización;
- los buckets públicos actuales no se consideran aislamiento SaaS suficiente sólo por incluir un prefijo.

No se aprobará el gate de seguridad multi-tenant mientras un asset sensible pueda ser enumerado o leído cross-tenant por diseño accidental.

---

## 14. `core_logic` y clientes Flutter

`core_logic` deberá tener un contexto de organización de primera clase; no debe descubrir el tenant mediante constantes.

Reglas:

- eliminar progresivamente `businessId: '1'`;
- `BusinessFiscalProfileKey.businessId` representará el identificador real de organización mientras se mantenga ese nombre de dominio;
- gateways y repositorios recibirán/resolverán el contexto desde la sesión autenticada, no desde globals singleton;
- caches locales se particionarán por `organization_id`;
- al cerrar sesión se limpia todo estado/cache tenant-scoped;
- V1 no muestra selector de organización porque una cuenta sólo tiene una empresa.

La UI puede ocultar opciones, pero nunca será el mecanismo de aislamiento.

---

## 15. Estados y revocación

### `app_users.status`

- `active`: puede obtener contexto tenant si la organización está activa;
- `disabled`: no puede operar aunque Auth conserve una sesión válida.

### `organizations.status`

- `active`: operación normal;
- `suspended`: operaciones normales de negocio bloqueadas;
- `closed`: operaciones normales bloqueadas; estado terminal a nivel de producto salvo proceso administrativo explícito.

La revocación de acceso se valida en backend en cada operación crítica; no depende sólo de esperar a que expire el JWT.

---

## 16. Operaciones de plataforma

No se creará un rol de "superadmin global" consumible desde Flutter con acceso irrestricto a todas las tablas.

Las tareas legítimas de plataforma que necesiten alcance global deberán:

- vivir en backend/control administrativo separado;
- usar credenciales de sistema no expuestas al cliente;
- elegir el tenant de forma explícita;
- auditar acciones sensibles;
- no reutilizar policies de usuario final como bypass.

---

## 17. Estrategia de migración derivada

La implementación seguirá patrón **expand -> backfill -> enforce -> contract**.

1. crear `organizations`;
2. crear `app_users` y una organización legacy de laboratorio;
3. vincular el usuario administrador actual a esa organización;
4. separar `empleados` de Auth;
5. introducir helpers tenant-aware;
6. añadir `organization_id` por grupos de dominio, inicialmente de forma migrable;
7. backfill determinista de datos existentes al tenant legacy;
8. crear índices/FKs compuestas/unicidades por empresa;
9. endurecer `NOT NULL` y RLS;
10. retirar paths singleton sólo después de pruebas verdes.

No se añadirá `organization_id` a todas las tablas en una sola migración.

---

## 18. Invariantes que ningún cambio futuro puede romper

1. Una fila tenant-owned siempre tiene un tenant definido al quedar operativa.
2. Un usuario final nunca elige su autoridad de tenant mediante un parámetro confiado.
3. Un `app_user` V1 pertenece a una sola organización.
4. Un empleado puede existir sin cuenta Auth.
5. Un empleado con cuenta sólo puede vincularse a un `app_user` de su misma organización.
6. Ninguna relación entre tablas tenant-owned puede apuntar silenciosamente a otro tenant.
7. Roles/permisos jamás sustituyen el filtro de `organization_id`.
8. `service_role` no exime a Edge Functions de hacer scope por tenant.
9. Caches locales y Storage deben estar particionados por tenant.
10. `configuracion_negocio.id = 1` y equivalentes no pueden reaparecer como arquitectura nueva.

---

## 19. Fuera de alcance de V1

- una identidad Auth con membresías simultáneas en múltiples empresas;
- compartir clientes/productos/inventario entre tenants;
- consolidación financiera multiempresa para usuarios finales;
- selector manual de tenant en Flutter;
- roles configurables completos (Bloque 4);
- suscripciones y billing (Bloque 7).

Estas capacidades futuras no deben impedirse, pero tampoco deben debilitar el aislamiento V1.

---

## 20. Criterios de aceptación de Fase 0.2

- [x] raíz de tenant definida: `organizations`;
- [x] tipo de ID definido: UUID;
- [x] regla V1 una cuenta -> una empresa definida;
- [x] separación Auth / app user / empleado definida;
- [x] autoridad del tenant definida exclusivamente en backend;
- [x] estados de organización/usuario definidos;
- [x] estrategia de `organization_id` directo definida;
- [x] FKs cross-tenant compuestas definidas;
- [x] unicidades por empresa definidas;
- [x] contrato de email Auth vs empleado definido;
- [x] decisión de `personas_cache` global/interna definida;
- [x] contrato de RLS/RPC/trigger/view definido;
- [x] contrato Edge Functions/service-role definido;
- [x] contrato Storage definido;
- [x] contrato `core_logic`/cache definido;
- [x] estrategia de migración definida;
- [x] no se realizaron cambios destructivos ni migraciones operativas en esta fase.

## Resultado de Fase 0.2

**APROBADA.** El contrato técnico de tenant queda congelado como referencia para la implementación. Cualquier migración que contradiga estas invariantes debe corregirse antes de avanzar.

La siguiente fase autorizada es **Fase 0.3 — Gate de regresión y anti-singleton**.
