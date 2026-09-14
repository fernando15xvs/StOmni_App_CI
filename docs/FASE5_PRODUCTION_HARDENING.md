# Fase 5 — Cierre real de producción

Inicio: 2026-08-21  
Base: `main` posterior a Fase 4 (`f37d6df7a01a9f3fcda93b20e55e58396b6e37db`)  
Rama: `hardening/production-phase5-20260821`

## Objetivo

Cerrar los riesgos de producción encontrados después de Fase 4 sin mezclar cambios destructivos, sin reescribir producción a ciegas y manteniendo una ruta verificable de rollback/reconstrucción.

## Reglas de la fase

- Roles técnicos únicamente `admin` y `operador`.
- Mantener el PR en Draft hasta completar checkpoints y smoke final.
- No fusionar a `main` sin autorización explícita.
- No aplicar DDL a Supabase producción sin migración revisada, prueba descartable y autorización explícita.
- No usar `execute_sql` para DDL de producción.
- No ejecutar `db reset --linked` contra producción.
- Cada checkpoint de código debe terminar con analyzer/tests/CI verde.
- Los cambios de base se prueban primero en un entorno local/temporal.

## Checkpoints

### 0. Preparación ✅

- Rama desde `main` estable.
- PR #5 Draft.
- Documentación de control.

### 1. Reproducibilidad Supabase 🚧

Completado:

- historial remoto inspeccionado en solo lectura;
- 10 migraciones remotas vs 13 timestamped históricas en Git al iniciar Fase 5;
- baseline `20260722180810_remote_schema.sql` confirmado vacío;
- huella inicial `public`: 44 tablas, 2 vistas, 74 funciones, 16 triggers, 58 policies y 145 índices;
- diferencias semánticas iniciales documentadas;
- `temp_functions.sql` retirado de `migrations/` porque era JSON, no SQL;
- script seguro `scripts/fase5_supabase_snapshot.ps1` agregado;
- `supabase/.temp/` y `supabase/.snapshots/` ignorados por Git.

Pendiente:

- generar dump oficial del schema con Supabase CLI;
- construir baseline candidato;
- ejecutar reconstrucción en entorno descartable;
- comparar schema reconstruido contra producción;
- recién después reconciliar historial remoto.

Ver `docs/FASE5_SUPABASE_RECONCILIATION.md`.

### 2. Idempotencia de pagos de deuda ✅ código / ⏳ SQL temporal-producción

Implementado:

- `DebtPaymentRequestStore` persiste el UUID de una intención de pago;
- huella por usuario/tipo/deuda/monto/saldo/método/Caja;
- error incierto conserva UUID; éxito confirmado lo limpia;
- `20260821224600_debt_payment_idempotency.sql`;
- tabla interna `pagos_deuda_requests`;
- `request_id` único/auditable en `pagos_venta` y `pagos_gasto`;
- RPC `procesar_pago_deuda_v2` con `FOR UPDATE`, roles `admin`/`operador`, validación y replay idempotente;
- Flutter usa v2 en la rama Fase 5;
- repositorio de Deudas encapsula fallos con `UserFacingException` y conserva el request ante resultado incierto.

Pendiente:

- ejecutar SQL en entorno temporal;
- simular respuesta perdida + retry;
- desplegar backend antes del nuevo cliente;
- tras smoke, revocar RPC legacy no idempotente.

### 3. Integridad de almacenes ✅ código / ⏳ SQL temporal-producción

Implementado:

- `20260821230200_warehouse_deactivation_integrity.sql`;
- RPCs seguras de desactivación/reactivación, solo admin activo;
- baja bloqueada con cualquier stock distinto de cero;
- inventario serializa movimientos contra la desactivación;
- almacén inactivo no puede recibir stock distinto de cero;
- DELETE físico se revoca en la migración;
- Flutter usa RPC y ya no cambia `activo` ni elimina físicamente desde el repositorio.

Pendiente:

- ejecutar SQL en entorno temporal;
- smoke con stock, almacén vacío y movimiento concurrente.

### 4. Sincronización SQLite ✅

- `AlmacenSyncContract` con selección explícita del esquema remoto;
- `select('*')` retirado del sync de productos;
- allowlist remoto → caché para productos, almacenes y proveedores;
- paginación por cursor `id > ultimoId`, `ORDER BY id`, `LIMIT 1000`;
- sync individual usa el mismo contrato;
- pruebas con 1501 productos, columna desconocida y cursor inválido.

Validación: CI #332 ✅

### 5. Autorización offline con TTL ✅

- TTL máximo: 24 horas desde `validatedAt`;
- timestamp inválido/corrupto falla cerrado;
- usuario distinto o rol no permitido falla cerrado;
- más de 5 minutos de timestamp futuro falla cerrado;
- solo una validación remota válida renueva el snapshot.

Validación: CI #332 ✅

### 6. Estabilidad Flutter 🚧

Completado:

- producción confirma `tipo_venta`: 199 `CAJA_UNIDADES` y 2 `PAQUETES`; no requiere migración legacy inmediata;
- proveedores administrativos separados de proveedores operativos activos;
- nuevos gastos e Ingreso de Mercadería usan proveedores activos;
- Ingreso de Mercadería carga bases en paralelo, protege `mounted`, muestra fallo recuperable y `Reintentar`;
- limpieza de imágenes es reference-aware ante reemplazo/error/resultado incierto;
- imagen anterior solo se elimina después de comprobar que PostgreSQL referencia la nueva;
- URLs externas no se convierten en rutas borrables del bucket.

Pendiente:

- compatibilidad Web real del selector/subida de producto (`File` → bytes/XFile/CroppedFile + `uploadBinary`).

### 7. Errores amigables y bootstrap resiliente ✅ principal / 🚧 barrido residual

Completado:

- `ErrorMapper` centraliza Caja Chica cerrada y saldo insuficiente sin exponer PostgREST/SQLSTATE;
- `DeudasRepository` entrega errores aptos para UI y mantiene idempotencia del pago;
- `DeudasPage` diferencia cartera vacía de fallo remoto, muestra mensaje seguro + `Reintentar` y dispone `TabController`;
- bootstrap renderiza `_BootstrapShell` antes de inicializar dependencias remotas;
- fallo crítico muestra UI segura + `Reintentar` en vez de pantalla vacía;
- inicialización crítica es idempotente para DB/Supabase/Preferences/localización;
- `.env` ausente puede degradar a `dart-define`;
- AppTime/configuración/OneSignal no bloquean el arranque;
- fallo de OneSignal queda en logs y no impide usar la app.

Pendiente:

- barrer pantallas legacy restantes que aún construyen texto con excepciones crudas;
- revisar momento UX del prompt de permisos de notificaciones.

### 8. Presentación ⏳

Diagnóstico:

- `pubspec.yaml` declara `1.0.0+1`, pero Splash mantiene un literal `Versión 2.0.0`;
- no se reemplazará por otro literal: debe existir una fuente única reproducible;
- PDFs actuales usan fuentes base Helvetica y los tests reportan falta de soporte Unicode;
- cotización intenta renderizar además un glifo Material no soportado.

Pendiente:

- fuente Unicode embebida/reproducible para PDF, sin depender de Internet;
- retirar/reemplazar el glifo no portable;
- versión visible obtenida desde metadata real del build.

### 9. Plataformas 🚧

Completado:

- iOS declara `NSCameraUsageDescription` y `NSPhotoLibraryUsageDescription`;
- nombre visible/bundle name de iOS alineado a `StOmni`;
- auditoría documentada en `docs/FASE5_DISTRIBUTION_READINESS.md`.

Pendiente de identidad/secretos del propietario:

- Android todavía usa `com.example.ferreteria_app`;
- Android Release todavía firma con clave debug;
- iOS todavía usa Bundle ID `com.example...`;
- iOS no tiene `Runner.entitlements`/`aps-environment`, por lo que APNs/OneSignal iOS no está listo para distribución;
- definir IDs finales y firma sin versionar keystores/certificados privados.

### 10. Supabase Advisors ✅ diagnóstico + migración candidata / ⏳ prueba y despliegue

Completado en solo lectura:

- Advisors de Security y Performance clasificados;
- helpers con `search_path` mutable inspeccionados;
- trigger helpers `set_facturacion_updated_at` y `set_vendedor_observaciones_kardex` confirmados como necesarios pero no como API RPC;
- `_gre_empleado_activo()` confirmado como dependencia directa de policies RLS GRE: no se revoca a `authenticated`;
- `_gre_supervisor()` no mostró consumidores reales actuales;
- `increment_stock` no tiene caller Flutter ni dependencia pública detectada y queda como helper legacy a cerrar;
- dos UNIQUE idénticos de `(producto_id, almacen_id)` confirmados como constraints reales;
- `series_select_empleado` confirmado con `auth.uid()` reevaluado por fila.

Migración candidata versionada:

- `20260822002000_advisor_safe_hardening.sql`;
- fija `search_path` de helpers necesarios;
- revoca EXECUTE directo de trigger helpers/legacy donde es seguro;
- conserva `_gre_empleado_activo()` para RLS;
- optimiza `series_select_empleado` con `(SELECT auth.uid())`;
- elimina el duplicado mediante `DROP CONSTRAINT ...key1`, no `DROP INDEX`.

**No se aplicó en producción.** Debe probarse primero en reconstrucción/entorno descartable.

Ver `docs/FASE5_SUPABASE_ADVISORS.md`.

### 11. Conciliación de stock ✅

Auditoría ejecutada en producción únicamente con SELECT:

- 185 filas de `inventario_almacen`;
- 185/185 coinciden con el último `saldo` del Kardex cuando el orden correcto es `inventario_movimientos.id DESC`;
- 0 diferencias Kardex;
- 0 filas sin Kardex;
- 1 stock negativo total;
- 0 negativos no permitidos;
- el único negativo pertenece a un producto con `permitir_sin_stock=true` y coincide con su Kardex.

Hallazgo metodológico:

- `fecha` es fecha de negocio y puede ser retroactiva/no reflejar el orden de aplicación;
- ordenar el último movimiento por `fecha` produjo 4 falsos positivos;
- `inventario_movimientos.id` es `bigint IDENTITY BY DEFAULT`, usa `inventario_movimientos_id_seq` y al auditar estaba alineado (`max(id)=289`, `last_value=289`).

Se agregó `scripts/fase5_stock_reconciliation.sql`, estrictamente read-only, y una guarda arquitectónica que impide introducir escrituras.

**No se requiere corrección de stock ni UPDATE manual.**

### 12. Integration/E2E + builds finales 🚧

- no existe actualmente carpeta `integration_test`;
- CI validaba Analyzer + Tests y en Fase 5 se añadió `flutter build web --release` a la misma guarda;
- falta definir E2E mínimo hermético o smoke automatizado para los flujos críticos;
- Android/iOS Release de distribución final depende de los IDs/firma indicados en Checkpoint 9.

Pendiente de smoke final:

- venta contado;
- venta crédito + pago idempotente;
- offline/reconexión;
- traslado + alertas;
- desactivación segura de almacenes;
- reconstrucción limpia de la base;
- builds Release finales de plataformas objetivo.

## Validación automática

- CI #323: idempotencia + almacenes ✅
- CI #332: sync SQLite + TTL offline ✅
- CI #338: analyzer limpio; guarda antigua de proveedores detectada y corregida.
- CI #346: analyzer limpio; guarda antigua del literal de Storage detectada.
- CI #347: Analyze + Tests ✅ para lifecycle/proveedores/imágenes.
- CI #360: Analyze + Tests ✅ antes de añadir la guarda Web.
- CI final de este HEAD debe validar Analyzer + Tests + `flutter build web --release`.

## Estado de producción

**Supabase producción no ha recibido DDL de Fase 5.**

Las consultas de conciliación y Advisors ejecutadas contra producción fueron solo lectura. Las migraciones de Fase 5 siguen preparadas para validación y no deben aplicarse hasta probarlas contra un entorno descartable y autorizar expresamente el despliegue.
