# Plan local de implementación: núcleo reutilizable y clientes móvil/desktop

**Estado:** propuesto para ejecución local  
**Alcance:** `packages/`, `supabase/migrations/`, `scripts/`, pruebas y documentación.  
**Fuera de alcance:** `.github/`, workflows, pull requests, pushes y despliegues remotos.

## Decisión vigente para el contrato de productos (2026-09-22)

StOmni se está construyendo como una aplicación nueva. No existe una población productiva ni datos reales que obliguen a conservar aliases o formatos históricos de productos. Por tanto:

- no se mantienen aliases de tipos de venta por compatibilidad;
- el único conjunto persistido es `UNIDAD`, `CAJA`, `PAQUETE`, `CAJA_PAQUETES` y `CAJA_UNIDADES`;
- los perfiles de presentaciones usan exclusivamente `schema_version: 2`;
- cualquier ausencia o código no canónico falla de forma explícita;
- las migraciones históricas no se reescriben: el estado final se corrige mediante una migración nueva;
- `ProductUnitProfile` configura presentaciones y precisión; no define aliases alternativos para `tipo_venta`.

## Resultado buscado

StOmni tendrá un núcleo que concentre reglas de negocio reutilizables y dos
clientes de presentación:

```text
mobile_app  ─┐
             ├──> core_logic (dominio, aplicación y puertos)
desktop_app ─┘
                    └──> adaptadores de datos/plataforma por interfaces
```

Al cerrar el plan:

- Las pantallas sólo construyen comandos, presentan estados y traducen errores.
- `core_logic` no contiene widgets, `BuildContext`, navegación, diálogos,
  permisos visuales, lifecycle de app ni selección/compartición de archivos.
- Los casos de uso reciben dependencias por constructor; no dependen de `Ref`.
- Los mapas se limitan a adaptadores Supabase, SQLite, JSON y compatibilidad
  temporal; dominio y aplicación exponen tipos.
- Móvil y desktop ejecutan los mismos casos de uso de inventario, ventas,
  sesión, permisos y sincronización.
- Al menos el 80 % de las reglas funcionales se prueba sin widgets.

## Reglas de ejecución

1. Trabajar por migración incremental; no hacer movimientos masivos de archivos.
2. No crear adaptadores de compatibilidad para contratos de producto obsoletos. Los consumidores se migran al contrato canónico en el mismo cambio.
3. Las migraciones serán aditivas y se crearán sólo en el árbol local. No se
   aplicarán a un proyecto Supabase remoto como parte de este plan.
4. Ejecutar Flutter de forma secuencial. Si el SDK se bloquea, registrar y
   resolver ese bloqueo antes de declarar una fase cerrada.
5. No editar `.github/` ni usar GitHub como mecanismo de verificación.
6. No borrar ni restaurar cambios locales ajenos sin autorización explícita.

## Estado de partida verificado

- El workspace ya contiene `core_logic`, `mobile_app` y `desktop_app`.
- Inventario tiene `SaveProductUseCase`; ventas tiene `SaleCart`,
  `ProcesarVentaCommand` y cálculos tipados iniciales.
- Desktop cuenta con bootstrap, autenticación, dashboard e inventario, pero
  Ventas aún no tiene un flujo funcional.
- El paquete móvil ahora se llama `mobile_app`. El guard de arquitectura debe
  detectar tanto ese nombre como el legado `ferreteria_app` hasta que la
  búsqueda de referencias antiguas sea cero.
- Quedan adaptadores de plataforma, servicios estáticos y mapas en
  `core_logic`; por ello la separación aún no está finalizada.

## Definición de terminado común

Cada fase requiere:

- Pruebas unitarias de tipos, puertos y casos de uso sin widgets.
- Ninguna consulta directa a Supabase, SQLite o Storage desde páginas/widgets.
- Ningún nuevo punto público basado en `Map<String, dynamic>`.
- Pruebas de rechazo para formatos no canónicos y pruebas de round-trip para el contrato vigente.
- Análisis y pruebas locales de los paquetes afectados, ejecutados uno por uno.
- Actualizar este documento con archivos migrados, adaptadores retirados y
  riesgos pendientes.

## Fase 0 — cerrar la base local

**Objetivo:** un workspace coherente y una verificación local repetible.

1. Consolidar el nombre `mobile_app`:
   - Buscar `package:ferreteria_app/` en `packages/` hasta obtener cero.
   - Ejecutar `flutter pub get` desde la raíz para regenerar configuración
     local del workspace.
   - Mantener un único nombre canónico y migrar todos sus consumidores en el mismo cambio.
2. Finalizar la limpieza mecánica:
   - Eliminar imports duplicados restantes de `core_logic/lib` y
     `core_logic/test`.
   - Convertir `scripts/clean_imports.dart` en utilidad segura con
     `--check` y `--write`; debe limitarse a rutas explícitas.
   - Aplicar `dart format` sólo a archivos modificados.
3. Crear `scripts/verify_workspace.ps1` para ejecutar secuencialmente:
   - analyze y test de `packages/core_logic`;
   - analyze y pruebas arquitectónicas de `packages/mobile_app`;
   - analyze, smoke test y build local del destino desktop elegido.
4. Ampliar guards locales:
   - `core_logic` no importa `mobile_app` ni `desktop_app`;
   - `domain`, `application` y `usecases` no importan Flutter UI,
     Supabase ni plugins de plataforma;
   - páginas/widgets no importan `supabase_flutter` ni usan
     `Supabase.instance`.

**Cierre:** imports antiguos/duplicados en cero, script local repetible y guards
que fallen ante una regresión deliberada.

## Fase 1 — fronteras, puertos e inyección de dependencias

**Objetivo:** que las reglas no dependan de Flutter, Riverpod ni de una
infraestructura concreta.

1. Adoptar esta estructura incremental dentro de `core_logic`:

   ```text
   lib/
     shared/{domain,application,ports}/
     features/<modulo>/{domain,application,ports}/
     infrastructure/{supabase,sqlite,storage}/
   ```

   Los archivos existentes pueden permanecer temporalmente en `data/`, pero
   cada implementación debe depender de un puerto de `ports/`.
2. Sustituir `Ref` en clases de negocio por constructor injection. Los
   providers se ubican en los puntos de composición de `mobile_app/app` y
   `desktop_app/app`.
3. Extraer de core los conceptos de aplicación:
   - `AppLifecycleListener` de `realtime_sync_service.dart`;
   - detección de conectividad de `connectivity_sync_controller.dart`;
   - dependencias remanentes de notificaciones móviles;
   - imports Material residuales, incluido `local_db_service.dart`.
4. Definir puertos iniciales: `ProductRepository`, `SaleRepository`,
   `SessionRepository`, `PendingOperationStore` y `DocumentDataGateway`.

**Cierre:** los casos de uso se instancian con fakes y los guards escanean todo
`core_logic/lib`, no sólo subcarpetas seleccionadas.

## Fase 2 — completar inventario y productos

**Objetivo:** terminar la primera vertical reutilizable antes de generalizar el
resto del sistema.

1. Dividir `SaveProductUseCase` en:
   - `ValidateProductUseCase`;
   - `CreateProductUseCase`;
   - `UpdateProductUseCase`;
   - `InitializeInventoryUseCase`;
   - `ReplaceProductImageUseCase`.
2. Introducir `ProductDraft`, `Product`, `Warehouse`,
   `InventoryBalance`, `InitialInventoryCommand` y `ProductImage`.
3. Confinar mapas a mappers de repositorios, SQLite y Storage. El selector de
   imagen vive en los clientes; el core recibe bytes o referencia por puerto.
4. Migrar consumidores móviles en este orden:
   - nuevo producto y su controller;
   - ingreso de mercadería y movimiento de stock;
   - almacenes, búsqueda, kardex y reportes de inventario.
5. Añadir pruebas de validación, duplicados, stock inicial, rollback,
   idempotencia, imágenes y errores de negocio.

**Cierre:** ningún controller de almacén contiene reglas de stock/precio ni
consultas directas; desktop puede crear, editar y consultar usando los mismos
comandos.

## Fase 3 — modelos tipados y unidades configurables

**Objetivo:** reemplazar caja/paquete/unidad rígidos sin romper productos
existentes.

1. Consolidar `CommercialPresentation` y `ProductUnitProfile`: unidad base,
   símbolo, precisión decimal y presentaciones con factor de conversión.
2. Mantener `SaleUnitType` como topología comercial canónica de cinco códigos.
   `ProductUnitProfile` v2 es la única configuración de presentaciones,
   precisión y escala; no existe un segundo contrato de aliases.
3. No crear mappers de aliases históricos. Los presets de `SaleUnitType` generan perfiles canónicos cuando se necesita una configuración de presentaciones.
4. Crear una migración local nueva que cierre defaults, checks y writers canónicos en
   `supabase/migrations/` con backfill y rollback lógico.
5. Aceptar cantidades decimales de manera coherente en inventario, carrito,
   kardex y documentos.

**Cierre:** botella/pack, metro/rollo y kilogramo/saco funcionan sin añadir un
enum o condicional por sector.

## Fase 4 — cerrar ventas reutilizables

**Objetivo:** una venta se expresa mediante un comando tipado independiente de
la pantalla móvil y de payloads de mapas.

1. Completar `SaleDraft`, `SaleLine`, `SaleTotals`, `Payment`,
   `SaleCustomer`, `SaleResult` y errores de dominio.
2. Separar `ProcesarVentaUseCase` en validación, pricing, preparación de
   persistencia y coordinación transaccional; inyectar puertos por constructor.
3. Usar `SaleLinePersistenceMapper` y DTOs tipados en el límite de persistencia;
   serializar mapas/JSON únicamente dentro de adaptadores de infraestructura.
4. Tipar la cola offline (`PendingSale`) y serializar JSON sólo dentro de
   `PendingOperationStore`.
5. Migrar `CarritoController` a `SaleCart` y hacer que ambos clientes
   construyan el mismo `ProcesarVentaCommand`.

**Cierre:** no quedan `List<Map<String, dynamic>>` en carrito, draft, pago o
líneas de venta; una prueba de contrato ejecuta la misma venta desde los dos
clientes.

## Fase 5 — perfil de negocio, capacidades y autorización

**Objetivo:** eliminar decisiones por sector y roles hardcodeados.

1. Crear `BusinessProfile` y `BusinessCapabilities` con capacidades para
   inventario, almacenes múltiples, crédito, facturación electrónica, lotes,
   vencimientos, variantes, servicios, proveedores, compras y series.
2. Sustituir el singleton `ConfiguracionService` por repositorio y casos de
   uso tipados.
3. Introducir `Permission`, `PermissionSet` y `AuthorizationPolicy`.
   Mapear temporalmente `admin` y `operador` a permisos para conservar
   usuarios actuales.
4. Mover checks de permisos a casos de uso; la UI sólo decide visibilidad.
5. Si el esquema no basta, crear migración local aditiva para capacidades, sin
   renombrar tablas existentes.

**Cierre:** activar una capacidad no exige `if (sector == ...)` y
`products.change_price` se prueba sin pantalla.

## Fase 6 — política fiscal desacoplada

**Objetivo:** conservar SUNAT sin convertirla en requisito de todo el motor.

1. Definir `FiscalPolicy` y contratos de validación/emisión.
2. Mover reglas de boleta, factura, DNI, S/700 y fechas desde
   `ProcesarVentaUseCase` a `PeruSunatFiscalPolicy`.
3. Añadir una política neutral para ventas internas o negocios sin facturación
   electrónica.
4. Mantener repositorios/RPC SUNAT como infraestructura peruana y probar sus
   contratos con fakes antes de llamar a Supabase.

**Cierre:** una venta genérica no conoce términos SUNAT y la política peruana
conserva las reglas actuales.

## Fase 7 — sesión, sync, plataforma y documentos

**Objetivo:** separar eventos de dispositivo y salida de archivos de reglas
compartidas.

1. Reemplazar `SplashService` por `ValidateSessionUseCase`,
   `SessionSnapshot` y `SessionValidationResult`. Cada cliente representa
   carga, login o error como corresponda.
2. Crear `SyncPendingOperationsUseCase`; cada cliente detecta conectividad y
   lifecycle y luego invoca el caso de uso.
3. Extraer impresión, share, file picker y rutas de plataforma de
   `PdfAssetLoader`/`PdfGeneratorService`. Core recibe `DocumentAssets` y
   devuelve bytes/modelos; los clientes implementan `DocumentOutputPort`.
4. Retirar de `core_logic/pubspec.yaml` plugins exclusivamente móviles cuando
   todos los callers usen adaptadores de cliente.

**Cierre:** core genera un documento con logo inyectado y sincroniza una cola
sin saber si la llamada vino de Android, Windows o macOS.

## Fase 8 — completar clientes móvil y desktop

**Objetivo:** demostrar que ambos clientes consumen la misma aplicación.

1. Desktop:
   - reemplazar el placeholder de Ventas por búsqueda, carrito, pagos y envío
     de `ProcesarVentaCommand`;
   - completar alta/edición de producto y movimientos de inventario;
   - reutilizar sesión, permisos y capacidades;
   - implementar salida documental propia de escritorio.
2. Móvil:
   - dejar pages/widgets como adaptadores de formulario y estado visual;
   - mover ImagePicker, permisos, navegación de notificaciones, conectividad y
     compartir a `lib/platform/`;
   - eliminar accesos directos restantes a Supabase desde presentación.
3. Compartir fixtures y pruebas de contrato de inventario/ventas entre clientes.

**Cierre:** login, producto, stock y venta usan los mismos casos de uso en
móvil y desktop; las diferencias se limitan a UI/plataforma.

## Fase 9 — módulos restantes y nuevas capacidades

**Orden obligatorio:** clientes/proveedores → auth/permisos → sync/offline →
facturación → reportes/finanzas.

Para cada módulo aplicar el patrón: tipos de dominio, comandos y puertos,
infraestructura, migración de consumidores y eliminación de cualquier alias obsoleto.
Después de estabilizarlo, añadir de forma incremental:

- compras y órdenes de proveedor;
- variantes, listas de precio y promociones;
- lotes, vencimientos y números de serie;
- transferencias y ajustes de almacén;
- productos de servicio/no inventariables;
- métricas y dashboards configurables.

**Cierre:** cada capacidad nace en dominio/aplicación, tiene pruebas sin widgets
y es consumible por los dos clientes antes de crear una pantalla específica.

## Secuencia segura

```text
Fase 0 → Fase 1 → Fase 2 → Fase 3 → Fase 4 → Fase 5/6
                                            └→ Fase 7 → Fase 8 → Fase 9
```

- Fases 5 y 6 pueden avanzar juntas una vez que ventas sea tipada.
- Fase 7 puede iniciar tras Fase 1, pero su integración final espera sesión,
  permisos y documentos tipados.
- Desktop no implementa ventas antes de Fase 4 para evitar duplicar móvil.

## Registro de progreso

Al concluir cada fase, agregar aquí:

1. fecha y archivos migrados;
2. comandos locales ejecutados y resultado;
3. aliases o formatos no canónicos pendientes;
4. contrato canónico y decisión de esquema documentados;
5. riesgos abiertos antes de iniciar la fase siguiente.

### 2026-08-30 — Fase 0 en ejecución

- Eliminados los imports Dart duplicados detectados en `core_logic/lib` y
  `core_logic/test`.
- Añadidos guards locales para dependencias `core_logic → clientes`, UI en
  capas reutilizables y acceso directo a Supabase desde pages/widgets/
  presentation de móvil.
- Creado `scripts/verify_workspace.ps1` y endurecido
  `scripts/clean_imports.dart` con modos explícitos `--check` y `--write`.
- Las comprobaciones estáticas no detectan imports duplicados ni marcadores de
  Supabase en la capa de presentación.
- Pendiente: ejecutar análisis y tests Flutter. El toolchain local deja
  procesos Dart sin salida incluso para `flutter --version`; resolverlo antes
  de declarar la fase cerrada.
