# Fase 2 — GRE: dominio, repositorios y CI

Fecha: 2026-08-18

## Estado previo validado

- `flutter analyze`: sin errores ni warnings; permanecen 10 `info` conocidos en `nueva_guia_remision_page.dart`.
- `flutter test`: 17/17 antes de este checkpoint.
- Selector de ubigeos GRE validado manualmente.
- Consultas DNI/RUC validadas en Clientes, Proveedores, Venta/Cotización y Gestión de Transporte.

## Cambios de este checkpoint

### CI

Se agregó `.github/workflows/flutter_ci.yml` para ejecutar en los PR hacia `main`:

- `flutter pub get`
- `flutter analyze --no-fatal-infos`
- `flutter test`

El workflow usa Flutter `3.38.4`, alineado con el SDK mínimo registrado en `pubspec.lock`, evitando que una versión estable futura cambie unilateralmente las restricciones de dependencias.

### Ubigeos GRE

La consulta de `gre_ubigeos` salió del widget y ahora vive en:

`lib/features/facturacion/data/gre_ubigeos_repository.dart`

`GreUbigeoField` queda enfocado en presentación, debounce y selección.

### Reglas de ítems GRE

Se creó:

`lib/features/facturacion/domain/gre_item_rules.dart`

Concentra reglas puras para:

- unidad base `PK` / `NIU`;
- compatibilidad de `unidad_gre`;
- conversión comercial `caja` / `paquete` / `unidad` a `BX` / `PK` / `NIU`;
- unidades permitidas por `tipo_venta`;
- conversión a piezas/unidades base según `cantidad_por_caja`;
- compatibilidad con unidad personalizada `ZZ`;
- nombres de unidades SUNAT mostrados en UI.

Se añadieron 10 tests unitarios en:

`test/features/facturacion/gre_item_rules_test.dart`

## Siguiente corte

Migrar `nueva_guia_remision_page.dart` para:

1. usar `PersonaLookupRepository` en la búsqueda del destinatario;
2. usar `GreItemRules` en lugar de duplicar las reglas dentro de la página;
3. mantener intactas las reglas de emisión, transporte, fechas, payload y guardado;
4. validar con CI y smoke test antes de extraer más secciones del formulario.

No se modifica producción de Supabase ni Edge Functions en este checkpoint.
