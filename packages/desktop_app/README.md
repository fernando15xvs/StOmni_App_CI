# StOmni Desktop

Cliente Flutter de escritorio de StOmni. Este paquete contiene únicamente la
composición y presentación específicas de Windows/Linux/macOS; la lógica de
negocio compartida vive en `../core_logic`.

## Ejecutar

Desde `packages/desktop_app`:

```bash
flutter run -d windows \
  --dart-define=SUPABASE_URL=https://TU-PROYECTO.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=TU_ANON_KEY
```

En Linux cambia `-d windows` por `-d linux`. En macOS usa `-d macos`.

No se usa `.env` como asset del cliente desktop. La configuración de conexión
se inyecta al build mediante `--dart-define`.

## Estructura

- `lib/app/bootstrap.dart`: inicialización de SQLite/FFI, Supabase, preferencias
  y `ProviderScope`.
- `lib/app/app.dart`: tema y raíz de la aplicación.
- `lib/features/auth`: autenticación y restauración de sesión usando
  `AuthController` de `core_logic`.
- `lib/features/home`: shell de navegación específico de escritorio.

## Regla de arquitectura

`desktop_app` puede depender de `core_logic`, pero `core_logic` nunca debe
importar archivos de `desktop_app` ni widgets específicos de esta interfaz.
Los casos de uso, modelos, reglas de ventas, inventario y sincronización deben
permanecer reutilizables por móvil y escritorio.

## CI

La workflow principal ejecuta:

- `flutter analyze` para `core_logic`, `mobile_app` y `desktop_app`;
- tests de los tres paquetes;
- build Android de humo;
- build Linux desktop de humo.
