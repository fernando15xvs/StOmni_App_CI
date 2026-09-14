# Auditoría final validada — `feature/desktop-architecture-refactor`

> Documento canónico de cierre del refactor arquitectónico de StOmni. Las fases 0–9 están implementadas y el gate local integral terminó en verde sobre Windows. Este documento sustituye los estados parciales anteriores.

## 1. Punto de control validado

- Repositorio: `fernando15xvs/StOmni_App`
- Rama: `feature/desktop-architecture-refactor`
- HEAD de código validado antes de este commit documental: `1ae7c2bfc9eca5cddc111f65075500d5579c06da`
- `main`: `ccedbf7264df88307b2449461fd195f8a1d6e5de`
- Comparación al cierre: **528 commits por delante de `main`, 0 por detrás**.
- No existe merge a `main`.
- No se aplicaron las migraciones nuevas a Supabase remoto.
- No se consumieron GitHub Actions para este cierre; los commits finales usan `[skip ci]`.
- La validación se realizó localmente en Windows, incluyendo SQL seguro, analyze, tests y build Desktop.

## 2. Resultado ejecutivo

Las fases 0–9 de `docs/PLAN_LOCAL_MULTIPLATAFORMA.md` quedan **cerradas y validadas localmente**.

| Fase | Estado final | Evidencia principal |
|---|---|---|
| 0 — Base local/workspace | ✅ Cerrada | workspace y gate integral verdes |
| 1 — Fronteras, puertos y DI | ✅ Cerrada | guard arquitectónico + tests de límites |
| 2 — Inventario/productos | ✅ Cerrada | analyze/tests core y móvil |
| 3 — Unidades configurables/fracciones | ✅ Cerrada | Dart + SQL/pgTAP verdes |
| 4 — Ventas reutilizables | ✅ Cerrada | regresión de carrito, precios, cotización y documentos |
| 5 — Capacidades/autorización | ✅ Cerrada | permisos efectivos, CAS y contratos SQL |
| 6 — Política fiscal | ✅ Cerrada | fiscal units, FE/GRE/NC y contratos SQL |
| 7 — Sesión/sync/plataforma/documentos | ✅ Cerrada | tests offline, errores, PDF y arquitectura |
| 8 — móvil/Desktop | ✅ Cerrada | analyze/test de ambos clientes + build Windows |
| 9 — módulos finales | ✅ Cerrada | compras, variantes, trazabilidad, servicios, métricas + pgTAP |

No queda un módulo funcional pendiente dentro del alcance definido para este refactor.

## 3. Arquitectura final

La responsabilidad queda separada así:

- `packages/core_logic`: motor reutilizable de negocio, dominio, casos de uso, políticas, gateways/adapters compartidos y contratos tipados.
- `packages/mobile_app`: presentación/composición móvil y adaptadores específicos de plataforma.
- `packages/desktop_app`: presentación/composición Desktop consumiendo el mismo motor.
- PostgreSQL/Supabase: autoridad final para permisos, idempotencia, concurrencia, pricing, inventario, trazabilidad y capacidades críticas.

Desktop no implementa un segundo motor comercial. Variantes, lotes, series y servicios tampoco crean inventarios paralelos.

## 4. Bloques funcionales cerrados

### Inventario, productos y presentaciones

- Presentaciones configurables por producto.
- Cantidades fraccionarias mediante escala entera controlada (`FixedQuantity`/storage scale).
- Snapshot de presentación/escala en ventas, cotizaciones y documentos reversibles.
- Escala inmutable después de existir stock o historia para no reinterpretar operaciones previas.
- Ingresos, ajustes, traslados y mermas pasan por fronteras compartidas y RPC endurecidos.
- Administración de almacenes y ciclo de vida del producto se consumen mediante casos de uso.

### Ventas, precios y cotizaciones

- Carrito y reglas de venta compartidos en `core_logic`.
- Precio autoritativo server-side con listas/promociones por producto, presentación, cantidad y vigencia.
- Override manual protegido por permiso de descuento.
- Cotizaciones conservan snapshots comerciales al convertirse.
- Ticket Interno, boleta y factura permanecen bajo política fiscal/capacidades del negocio.

### Permisos y capacidades

- `AppPermission` + `OperationAuthorizer` compartidos.
- Overrides por empleado restrictivos respecto del rol base.
- RPC críticos revalidan al actor autenticado.
- Capacidades se actualizan con revisión CAS.
- Compras, variantes, servicios y trazabilidad se activan sólo cuando sus flujos existen.
- `expiryTracking` exige `lotTracking`.

### Compras

- Órdenes multi-producto.
- Recepciones parciales y múltiples.
- Idempotencia por `request_id`.
- Inventario fraccionario.
- Recepción normal, por lote o por serie en la misma orden.
- Móvil y Desktop consumen el mismo `PurchaseOrderUseCase`.

### Variantes

- Cada variante es un producto real con stock propio.
- El grupo de variantes aporta atributos y relaciones, no inventario alternativo.
- Administración disponible en móvil y Desktop.

### Trazabilidad — lote, vencimiento y serie

Cerrada end-to-end:

- configuración por producto;
- capacidades globales opt-in;
- stock por lote/serie;
- recepción de mercancía y compras;
- venta, traslado y merma trazables;
- FEFO/FIFO de lotes;
- FIFO determinista de series cuando no hay selección explícita;
- validación server-side de series explícitas;
- locking e idempotencia;
- comportamiento inerte mientras la capacidad global correspondiente esté apagada;
- configuración/cutover disponible en móvil y Desktop.

Migraciones principales:

- `20260906003000_inventory_lot_serial_traceability.sql`
- `20260906003500_traceability_capability_and_expiry_guard.sql`
- `20260906004000_traceable_sale_consumption.sql`
- `20260906004500_inert_traceability_until_capability_enabled.sql`
- `20260906005000_traceable_transfers_and_waste.sql`
- `20260906005500_traceable_movement_idempotency.sql`
- `20260906006000_traceable_purchase_receipts.sql`
- `20260906006500_serial_fifo_fallback.sql`
- `20260906007000_enable_traceability_capabilities.sql`
- `20260906007500_serial_fifo_json_hardening.sql`

### Servicios no inventariables

- Fuente de verdad: `productos.es_servicio`.
- Metadatos descriptivos persistidos en `service_metadata` para compatibilidad con el esquema legacy de productos.
- Reutilizan catálogo, pricing, cliente, pagos y comprobantes de venta.
- PostgreSQL normaliza invariantes de servicio y mantiene stock técnico en cero.
- No generan Kardex ni pueden entrar como mercancía de compra/trazabilidad.
- GRE rechaza servicios como carga física.
- Administración móvil y Desktop.

Migraciones:

- `20260906008000_non_inventory_services.sql`
- `20260906008500_enable_non_inventory_services.sql`
- `20260906009500_gre_service_cargo_guard.sql`

### Métricas configurables

- Catálogo cerrado de fuentes: ingresos, gastos, flujo neto, descuentos, cantidad de ventas y conteos de movimientos de inventario.
- No se ejecuta SQL o fórmula arbitraria configurada por usuario.
- Administración de nombre, orden y activación.
- Cálculo en `core_logic` sobre `ReportingSnapshot`.
- Entradas/salidas cuentan eventos; no suman magnitudes incompatibles como kg + metros + piezas.
- Superficie móvil y Desktop.

Migración:

- `20260906009000_configurable_business_metrics.sql`

## 5. Correcciones encontradas durante la validación

La validación local detectó y corrigió problemas reales y contratos desactualizados. Entre los más relevantes:

1. Colisiones de versión de migraciones Supabase; el guard ahora exige prefijos únicos.
2. El baseline histórico `20260722180810_remote_schema.sql` está vacío, por lo que un `db reset` fresco no puede reconstruir producción. Se creó un laboratorio seguro basado en snapshot remoto de solo lectura.
3. `business_capabilities.variants` faltaba en el replay pendiente.
4. Servicios dependían de una columna legacy inexistente (`productos.descripcion`); se movieron metadatos a `service_metadata` y se añadieron invariantes server-side.
5. Un wrapper posterior de permisos había eliminado accidentalmente la validación fiscal de `save_product_unit_profile_v6`; se restauraron ambas garantías.
6. Se endurecieron privilegios Data API efectivos para `clientes` y `transferencias_stock`, incluyendo revocación a `PUBLIC`.
7. Se corrigieron semánticas GRE para peso de cajas legacy y validación de servicios.
8. Se corrigió precedencia de validación en ventas legacy fraccionarias.
9. Se preservan etiquetas configurables de presentación sin forzar minúsculas.
10. Se alinearon APIs finales de sesión/permisos, inventario y fixtures de tests.
11. En móvil se sacó wiring Supabase de `presentation/` para respetar la frontera arquitectónica.
12. Se alineó la pantalla móvil de unidades con la API final de `ProductUnitSettings` y `SaveProductUnitConfigurationUseCase`.
13. Se alinearon constructores de recepción seriada en móvil/Desktop.
14. Tests arquitectónicos frágiles por nombres locales, indentación, CRLF o textos acentuados fueron reemplazados por contratos estructurales equivalentes sin rebajar la garantía funcional.

## 6. Validación SQL segura — resultado final

El flujo actual de `scripts/verify_refactor_local.ps1` detecta que el baseline histórico está incompleto y **no ejecuta `supabase db reset` sobre ese baseline**.

En su lugar ejecuta `scripts/verify_linked_schema_lab.ps1`, que:

1. consulta el ledger de migraciones remoto en modo lectura;
2. identifica la última versión realmente registrada en remoto (`20260822052115` durante esta validación);
3. exporta `public` mediante `supabase db dump --linked --schema public` sin modificar el remoto;
4. restaura el snapshot en un Supabase/PostgreSQL temporal local;
5. aplica sólo migraciones locales posteriores a la última versión remota;
6. ejecuta pgTAP;
7. ejecuta `supabase db lint --local --schema public --level error --fail-on error`;
8. destruye el laboratorio temporal sin escribir cambios al proyecto remoto.

Resultado final observado:

- migraciones pendientes en laboratorio: ✅
- pgTAP: ✅
- `db lint`: ✅
- Supabase remoto modificado por la validación: **NO**

## 7. Validación Flutter/workspace — resultado final

### `core_logic`

- `flutter analyze --no-pub --no-fatal-infos`: ✅ sin errores ni warnings fatales.
- `flutter test`: ✅ `All tests passed!`.

### `mobile_app`

- `flutter analyze --no-pub --no-fatal-infos`: ✅ sin errores ni warnings; quedaron únicamente infos no fatales.
- `flutter test`: ✅ **227 tests**, `All tests passed!`.

### `desktop_app`

- `flutter analyze --no-pub --no-fatal-infos`: ✅ sin errores ni warnings fatales.
- `flutter test`: ✅ **2 tests**, `All tests passed!`.
- `flutter build windows --debug`: ✅.

### Gate integral

Comando ejecutado desde la raíz:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify_refactor_local.ps1 -DesktopTarget windows
```

Resultado final:

```text
VALIDACIÓN LOCAL COMPLETA: todos los gates ejecutados terminaron correctamente.
```

Por tanto, la implementación ya no está solamente “cerrada en código”: está **validada por el toolchain local automatizado**.

## 8. Qué valida el gate integral actual

En orden:

1. `git diff --check`;
2. `node scripts/verify_architecture.mjs`;
3. `dart run scripts/validate_client_env.dart`;
4. gate SQL seguro:
   - laboratorio snapshot remoto de solo lectura cuando el baseline histórico está vacío/incompleto; o
   - Supabase local convencional si existiera un baseline reconstruible;
5. `scripts/verify_workspace.ps1`;
6. analyze/tests de los paquetes;
7. build del Desktop solicitado.

El guard SQL evita usar un reset ingenuo sobre un baseline que no contiene el esquema histórico.

## 9. Deuda técnica no bloqueante

No bloquea el cierre del roadmap ni el merge, pero conviene mantenerla registrada:

- `core_logic.dart` todavía exporta parte de infraestructura/providers por compatibilidad; puede reducirse gradualmente en refactors futuros.
- Existen infos de analyzer por imports redundantes y APIs Flutter/Supabase deprecadas (`anonKey`, ciertos controles `Radio`, etc.). No son errores ni warnings fatales del gate actual.
- Actualizar dependencias mayores debe tratarse como proyecto separado; no es parte de este refactor.
- La matriz de smoke manual de negocio sigue siendo recomendable antes de promover una release productiva, aunque el gate automatizado ya está verde.

## 10. Smoke manual recomendado antes de release

Validar manualmente como mínimo:

- login/logout/restauración offline y recuperación de conexión;
- permisos efectivos y overrides;
- edición de capacidades CAS;
- crear/editar producto y presentaciones;
- venta/cotización entera y fraccionaria;
- pricing/promociones y override autorizado;
- compra normal, parcial, por lote y por serie;
- venta/traslado/merma con lotes/series e idempotencia;
- activación/desactivación de trazabilidad respetando invariantes;
- crear/vender servicio comprobando stock cero, sin Kardex y sin GRE de mercancía;
- variantes;
- Ticket Interno, boleta/factura, nota de crédito y GRE;
- cola offline/sync y resolución de resultado incierto;
- reportes/métricas;
- equivalencia funcional móvil/Desktop.

## 11. Estado para merge y despliegue

A nivel de implementación y validación automatizada local, la rama está **lista para la etapa de promoción**.

Todavía NO se ejecutó:

- merge a `main`;
- aplicación de migraciones nuevas a Supabase remoto;
- despliegue actualizado a GitHub Pages;
- smoke manual productivo documentado.

Estas acciones deben hacerse como una etapa separada y controlada, preservando el orden recomendado:

1. revisar `git status` y sincronizar el último commit documental;
2. decidir/aplicar migraciones remotas de forma controlada;
3. ejecutar smoke funcional contra el entorno objetivo;
4. fusionar la rama con `main` cuando corresponda;
5. desplegar los clientes correspondientes.

## 12. Conclusión de auditoría

**Resultado: APROBADO para cierre del refactor y preparación de promoción.**

Las fases 0–9 están implementadas, el SQL pendiente fue probado sin modificar el remoto, los tres paquetes pasaron analyze/tests y Desktop compiló para Windows. El gate integral final terminó en verde. Las acciones restantes son de promoción/release, no de implementación del roadmap.