# Roadmap SaaS Multi-Tenant de StOmni

> Rama de trabajo: `feature/saas-multitenant-foundation`
>
> Objetivo: convertir StOmni en una plataforma SaaS para múltiples empresas, con aislamiento total de datos, módulos configurables y una base preparada para suscripción comercial.

## Principios no negociables

1. Cada empresa es un tenant independiente.
2. Ninguna empresa puede leer, modificar ni inferir datos de otra.
3. En la versión inicial, cada usuario de StOmni pertenece a una sola empresa.
4. `auth.users` sigue siendo la identidad de acceso; no se duplican contraseñas ni autenticación en tablas propias.
5. Los empleados pertenecen a una empresa y pueden existir sin acceso al sistema.
6. Toda operación crítica se valida en PostgreSQL/RLS/RPC; Flutter nunca es la barrera de seguridad.
7. La app no queda atada a un rubro: inventario, servicios, variantes, lotes, seriales, compras, etc. se activan por empresa.
8. Cada bloque se cierra con pruebas antes de comenzar el siguiente.
9. No se migran datos reales de clientes hasta que el aislamiento multi-tenant esté validado.
10. Las migraciones deben ser reversibles o tener estrategia de compensación y nunca depender de un singleton `id = 1`.

---

# BLOQUE 0 — Preparación y mapa de impacto

## Fase 0.1 — Inventario del modelo actual
- Identificar todas las tablas, vistas, RPC, triggers, policies y Edge Functions que asumen una sola empresa.
- Detectar referencias a `configuracion_negocio.id = 1` y equivalentes.
- Clasificar tablas en: globales, por empresa, internas de sistema y temporales.

## Fase 0.2 — Contrato de tenant
Definir el contrato técnico de aislamiento:
- `organizations` será la raíz de cada empresa.
- `app_users` vinculará `auth.users` con exactamente una empresa.
- `employees` será independiente del login.
- Las tablas de negocio usarán `organization_id`.
- Las claves únicas de negocio pasarán a ser compuestas por empresa cuando corresponda.

## Fase 0.3 — Gate de regresión
- Congelar pruebas actuales como baseline.
- Añadir pruebas de arquitectura que impidan introducir nuevas dependencias singleton.

**Gate Bloque 0:** mapa de impacto completo + tests actuales verdes.

---

# BLOQUE 1 — Fundación multiempresa

## Fase 1.1 — Tabla `organizations`
Crear la entidad empresa con datos mínimos:
- `id UUID`
- nombre legal/comercial
- país, moneda, zona horaria
- estado (`active`, `suspended`, `closed`)
- timestamps

## Fase 1.2 — Tabla `app_users`
Relación de acceso:
- `user_id UUID -> auth.users`
- `organization_id UUID -> organizations`
- estado
- rol base
- timestamps

Regla V1: un `user_id` sólo puede pertenecer a una empresa.

## Fase 1.3 — Separación de `employees`
- Añadir `organization_id`.
- Permitir empleado sin cuenta Auth.
- Permitir vínculo opcional entre empleado y `app_users`.
- Eliminar la dependencia conceptual `empleado == usuario`.

## Fase 1.4 — Bootstrap seguro de empresa
Crear un flujo idempotente que permita:
1. crear empresa;
2. crear primer administrador;
3. crear configuración inicial;
4. crear capacidades por defecto.

**Gate Bloque 1:** dos empresas de prueba creadas con administradores distintos.

---

# BLOQUE 2 — Seguridad e aislamiento real

## Fase 2.1 — Helpers de autorización
Funciones seguras para resolver:
- empresa del usuario autenticado;
- usuario activo;
- rol;
- permisos;
- pertenencia de una fila al tenant actual.

## Fase 2.2 — RLS multi-tenant
Para cada tabla expuesta:
- `organization_id` obligatorio cuando aplique;
- SELECT aislado;
- INSERT aislado;
- UPDATE aislado;
- DELETE aislado.

## Fase 2.3 — RPC tenant-aware
Cada RPC crítico debe:
- obtener empresa desde `auth.uid()`;
- ignorar cualquier `organization_id` manipulable enviado por cliente;
- validar permisos dentro de PostgreSQL;
- escribir siempre en el tenant autenticado.

## Fase 2.4 — Edge Functions tenant-aware
- Resolver empresa desde el usuario autenticado.
- Prohibir operaciones cruzadas.
- Mantener `verify_jwt = true`.

## Fase 2.5 — Test de ataque cruzado
Crear suite automatizada:
- Empresa A no puede leer Empresa B.
- Empresa A no puede insertar usando ID de Empresa B.
- Empresa A no puede actualizar/eliminar Empresa B.
- RPC y Storage también deben rechazar el cruce.

**Gate Bloque 2:** 100% de pruebas cross-tenant bloqueadas.

---

# BLOQUE 3 — Migración del dominio existente

Se migrará por grupos pequeños, no toda la base a la vez.

## Fase 3.1 — Configuración y capacidades
- Reemplazar `configuracion_negocio` singleton por configuración por `organization_id`.
- Convertir `business_capabilities` a configuración por empresa.
- Eliminar dependencias de `id = 1`.

## Fase 3.2 — Clientes y proveedores
- Añadir `organization_id`.
- Hacer únicos por empresa los identificadores que correspondan.
- Preparar evolución futura a entidad genérica `parties` sin bloquear la entrega actual.

## Fase 3.3 — Catálogo
- Productos, categorías, presentaciones, variantes, servicios y precios por empresa.
- SKU/código único dentro de la empresa, no globalmente.

## Fase 3.4 — Almacenes e inventario
- Almacenes por empresa.
- Existencias, kardex, lotes, seriales, mermas y transferencias aisladas.

## Fase 3.5 — Ventas, cotizaciones y pagos
- Ventas, detalles, pagos, crédito y devoluciones por empresa.

## Fase 3.6 — Compras y proveedores
- Órdenes, recepciones y costos por empresa.

## Fase 3.7 — Fiscal y documentos electrónicos
- Perfil fiscal por empresa.
- Correlativos independientes por empresa.
- Comprobantes, notas de crédito y GRE aislados.

**Gate Bloque 3:** todas las tablas operativas principales tienen tenant y no existe fuga cross-tenant.

---

# BLOQUE 4 — Estructura profesional de cada empresa

## Fase 4.1 — Sucursales
Crear `branches` por empresa.

## Fase 4.2 — Almacenes por sucursal
Relacionar almacenes con empresa y sucursal.

## Fase 4.3 — Cajas y puntos de operación
Preparar `cash_registers` / puntos de venta por sucursal.

## Fase 4.4 — Empleados por empresa
- ficha laboral;
- cargo;
- sucursal principal;
- estado;
- acceso opcional al sistema.

## Fase 4.5 — Roles y permisos configurables
Modelo:
- `roles`
- `permissions`
- `role_permissions`
- overrides por usuario cuando sea necesario.

**Gate Bloque 4:** una empresa puede tener múltiples sucursales, almacenes y roles sin afectar otra empresa.

---

# BLOQUE 5 — StOmni adaptable a distintos rubros

## Fase 5.1 — Capacidades por empresa
Activar/desactivar por tenant:
- inventario;
- compras;
- ventas a crédito;
- servicios;
- variantes;
- lotes;
- vencimientos;
- seriales;
- múltiples sucursales;
- múltiples almacenes;
- facturación electrónica.

## Fase 5.2 — Catálogo genérico
Evolucionar el concepto comercial hacia tipos configurables:
- producto con stock;
- producto sin stock;
- servicio;
- combo/paquete.

## Fase 5.3 — Campos y reglas configurables
Sin convertir la base en EAV libre:
- unidades;
- listas de precios;
- descuentos;
- impuestos;
- reglas comerciales;
- configuración visible por módulo.

## Fase 5.4 — UI dinámica
Flutter mostrará sólo los módulos habilitados para la empresa.

**Gate Bloque 5:** perfiles de negocio distintos funcionan con el mismo código base.

---

# BLOQUE 6 — Auditoría, automatización y analítica

## Fase 6.1 — Auditoría empresarial
Crear `audit_logs` con:
- empresa;
- usuario;
- acción;
- entidad;
- identificador;
- metadata segura;
- timestamp.

Cubrir inicialmente:
- cambios de precio;
- ajustes de stock;
- anulaciones;
- descuentos sensibles;
- cambios de permisos;
- cambios de configuración.

## Fase 6.2 — Alertas y automatizaciones
- stock bajo;
- vencimientos;
- deudas vencidas;
- compras pendientes;
- cierres de caja;
- tareas operativas relevantes.

## Fase 6.3 — Dashboard configurable
Métricas por empresa, sucursal y periodo:
- ventas;
- margen;
- rotación;
- inventario inmovilizado;
- cuentas por cobrar;
- gastos;
- rendimiento.

## Fase 6.4 — Asistente empresarial StOmni
Capa opcional y segura para responder sobre datos autorizados, por ejemplo:
- qué reponer;
- qué productos no rotan;
- por qué bajó el margen;
- qué clientes tienen deuda vencida.

El asistente nunca debe saltarse RLS ni recibir acceso global a todos los tenants.

**Gate Bloque 6:** auditoría completa de acciones críticas + métricas aisladas por empresa.

---

# BLOQUE 7 — Suscripciones y monetización

## Fase 7.1 — Catálogo de planes
Planes iniciales sugeridos:
- Starter
- Business
- Pro
- Enterprise

## Fase 7.2 — Suscripción por empresa
Modelo para:
- plan actual;
- estado;
- fecha de inicio/renovación;
- periodo de prueba;
- suspensión;
- límites contratados.

## Fase 7.3 — Entitlements
Los planes controlarán límites y funciones, por ejemplo:
- cantidad de usuarios;
- sucursales;
- almacenes;
- módulos Pro;
- automatizaciones;
- analítica avanzada;
- integraciones.

## Fase 7.4 — Enforcement backend
Los límites se validan en backend, no sólo ocultando botones.

## Fase 7.5 — Preparación para proveedor de pagos
Crear interfaz desacoplada para integrar un proveedor de cobros después, sin atar el dominio a uno específico.

**Gate Bloque 7:** una empresa suspendida o fuera de límites no puede eludir restricciones manipulando el cliente.

---

# BLOQUE 8 — Experiencia SaaS y onboarding

## Fase 8.1 — Alta de nueva empresa
Wizard:
1. datos básicos;
2. tipo de operación;
3. módulos necesarios;
4. sucursal inicial;
5. almacén inicial;
6. administrador.

## Fase 8.2 — Configuración guiada
Checklists dentro de la app para completar:
- negocio;
- impuestos;
- almacenes;
- empleados;
- catálogo;
- permisos.

## Fase 8.3 — Experiencia mobile / desktop / web
Mantener el mismo motor `core_logic`, adaptando la presentación a cada plataforma.

## Fase 8.4 — Branding por empresa
Preparar logo, nombre comercial y preferencias visuales sin permitir código ni assets inseguros.

**Gate Bloque 8:** una empresa nueva puede pasar de registro a primera operación sin intervención manual en DB.

---

# BLOQUE 9 — Hardening y salida comercial

## Fase 9.1 — Pruebas E2E multiempresa
Escenarios completos con Empresa A y Empresa B en paralelo.

## Fase 9.2 — Carga y concurrencia
- operaciones simultáneas;
- índices por `organization_id`;
- contención en inventario;
- correlativos;
- idempotencia.

## Fase 9.3 — Backups y recuperación
- política de backups;
- recuperación probada;
- exportación de datos por empresa.

## Fase 9.4 — Observabilidad
- logs técnicos;
- errores;
- métricas;
- trazabilidad de jobs y Edge Functions.

## Fase 9.5 — Seguridad final
- advisors;
- RLS;
- SECURITY DEFINER;
- Storage;
- secretos;
- rate limits;
- pruebas de aislamiento.

## Fase 9.6 — Release comercial
- web;
- desktop;
- Android/iOS;
- documentación operativa;
- soporte y onboarding.

**Gate Bloque 9:** checklist comercial y técnico 100% verde.

---

# Orden obligatorio

`Bloque 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9`

No se debe comenzar monetización, IA ni automatizaciones avanzadas antes de cerrar la seguridad multi-tenant.

# Estrategia de implementación

- Una fase = cambios pequeños y auditables.
- Cada fase tendrá migración SQL + pruebas cuando corresponda.
- Antes de modificar producción: laboratorio local y proyecto Supabase de prueba.
- Cada bloque cerrado se marca en `docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md`.
- Si una fase descubre deuda técnica, se registra antes de avanzar.
- No se fusiona a `main` una fase con tests rojos o aislamiento incompleto.
