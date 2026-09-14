# Fase 5.4 — UI dinámica por módulos

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Gate:

- `scripts/verify_saas_dynamic_modules_ui.mjs`

Test de dominio:

- `packages/core_logic/test/business/business_module_policy_test.dart`

Gate maestro del bloque:

- `scripts/verify_saas_adaptability_block.mjs`

## Objetivo

La interfaz deja de asumir que todas las empresas usan el mismo conjunto de módulos. Las capacidades configuradas en F5.1 determinan qué superficies aparecen en mobile y desktop, mientras el backend continúa siendo la barrera autoritativa de seguridad y consistencia.

F5.4 no convierte la UI en enforcement de seguridad. Ocultar una pantalla evita ruido funcional; los RPC, RLS, permisos y guards server-side siguen decidiendo si una operación es válida.

## Política compartida

`packages/core_logic/lib/business/application/business_module_policy.dart` define `BusinessModule` y `BusinessModulePolicy`.

La política se comparte entre plataformas para impedir divergencias como:

- Compras visibles en desktop pero ocultas en mobile;
- Inventario visible con `inventory_enabled=false`;
- Servicios o variantes habilitados en una plataforma y no en la otra;
- Facturación electrónica visible aunque la capacidad esté apagada.

Los módulos opcionales se derivan de `BusinessCapabilities`:

- Inventario y movimientos -> `inventoryEnabled`;
- Compras -> `purchaseManagement`;
- Servicios -> `services`;
- Variantes -> `variants`;
- documentos electrónicos -> `electronicInvoicing`;
- proveedores -> `supplierManagement`.

La configuración de módulos (`moduleSettings`) permanece siempre alcanzable para el administrador. Esto evita un dead-end donde el usuario apaga un módulo y después no dispone de una superficie para volver a activarlo.

## Desktop

`DesktopHomeShell` deja de usar una correspondencia fija `índice -> página` como contrato de navegación.

El estado seleccionado se conserva como `BusinessModule`. En cada render:

1. se calcula la lista visible según capacidades y rol;
2. se deriva el índice actual buscando la clave estable del módulo;
3. si un cambio de capacidades vuelve inválido el módulo activo, se retorna a Inicio;
4. el `NavigationRail` se genera desde los destinos visibles.

Esto evita que al ocultar, por ejemplo, Compras, un índice previamente asociado a Compras pase accidentalmente a Facturación u otra página.

Se añadió `DesktopBusinessModulesPanel`, accesible para administradores. El panel guarda mediante `UpdateBusinessCapabilitiesUseCase`; no escribe Supabase directamente.

Cuando una capacidad se guarda, el panel propaga el nuevo `BusinessProfile` al shell mediante `onProfileSaved`, por lo que el `NavigationRail` se regenera inmediatamente sin cerrar sesión.

## Mobile

`HomePage` carga `BusinessProfile` y trabaja fail-closed mientras las capacidades no estén disponibles: los módulos opcionales no se presentan hasta disponer del perfil.

El menú de Gestión usa la misma `BusinessModulePolicy` que desktop. `Módulos del negocio` permanece visible para el administrador incluso si todos los módulos opcionales están desactivados.

Después de volver de `ModulosNegocioPage`, `HomePage` recarga el perfil. Los cambios quedan reflejados sin reiniciar la aplicación.

La barra principal también se adapta a Inventario:

- Inicio y Balance permanecen;
- Almacén y Movimientos sólo existen cuando `inventoryEnabled=true`.

`CustomBottomNav` no divide ya el ancho en cuatro posiciones constantes. Construye `_items` dinámicamente y usa `items.length` para hit-testing, drag, alineación y render. Esto evita targets invisibles o índices inválidos cuando Inventario está apagado.

Si Inventario se desactiva mientras el usuario estaba en Almacén/Movimientos, `HomePage` mueve el tab activo a Inicio.

## Dependencias al editar capacidades

Los configuradores mobile/desktop construyen un `BusinessCapabilities` consistente antes de enviarlo al use case. Al apagar Inventario también apagan en el payload:

- múltiples almacenes;
- compras;
- lotes;
- vencimientos;
- números de serie.

Esto mejora UX, pero no sustituye los guards F5.1. PostgreSQL aún rechaza desactivar capacidades cuando los datos existentes violan invariantes, por ejemplo stock físico pendiente.

## Gate

`verify_saas_dynamic_modules_ui.mjs` comprueba:

- política centralizada en `core_logic`;
- dependencias capacidad -> módulo;
- `moduleSettings` siempre alcanzable;
- desktop seleccionado por clave estable;
- ausencia de `switch(_selectedIndex)` posicional como contrato de módulos;
- actualización inmediata del perfil desktop;
- menú Gestión mobile capability-driven;
- recuperación del perfil al volver de configuración;
- expulsión de tabs de inventario al desactivarse;
- bottom nav basado en `_items`/`items.length`, no cuatro posiciones fijas;
- uso del mismo use case de capacidades en ambas plataformas;
- tests de módulos core y opcionales.

El self-test muta contratos representativos para demostrar que el gate detecta regresiones.

## Validación dinámica pendiente

T13/T14/T15 deberán comprobar al menos:

- `flutter analyze` sin errores en core/mobile/desktop;
- tests de `BusinessModulePolicy` verdes;
- empresa con inventario apagado no muestra Almacén/Movimientos/Compras;
- empresa con Servicios apagado no muestra Servicios;
- empresa con Variantes apagado no muestra Variantes;
- empresa con facturación electrónica apagada no muestra Documentos electrónicos;
- un administrador puede reactivar módulos desde `Módulos del negocio`;
- cambios desktop actualizan el rail en caliente;
- cambios mobile actualizan UI al volver de configuración;
- navegación no cambia de página por desplazamiento accidental de índices.

## Resultado

F5.4 queda cerrada a nivel de implementación. StOmni tiene una política de módulos común a mobile y desktop y la visibilidad funcional responde a capacidades por empresa sin sustituir el enforcement backend.
