# Fase 2 — Bootstrap y raíz de aplicación

Fecha: 2026-08-18

## Objetivo

Reducir la responsabilidad de `lib/main.dart` sin cambiar reglas de negocio, navegación visible, autenticación, Supabase, OneSignal, preferencias ni comportamiento de lifecycle.

## Estructura creada

```text
lib/app/
├── app.dart
├── app_lifecycle.dart
├── app_router.dart
└── bootstrap.dart
```

## Responsabilidades

### `main.dart`

Queda limitado al entrypoint:

```dart
Future<void> main() => bootstrapApp();
```

### `bootstrap.dart`

Centraliza inicialización previa a `runApp`:

- binding de Flutter;
- base local por plataforma;
- `.env`;
- Supabase;
- sincronización de hora;
- configuración de negocio;
- preferencias;
- locale `es`;
- OneSignal;
- `ProviderScope`.

### `app.dart`

Contiene el widget raíz de StOmni:

- `MaterialApp`;
- tema claro/oscuro;
- localización;
- rutas;
- Splash inicial.

### `app_router.dart`

Centraliza:

- `navigatorKey` raíz;
- rutas con nombre existentes.

No se introduce un router nuevo ni se cambia el sistema de navegación actual.

### `app_lifecycle.dart`

Conserva la política anterior:

- al pausar, registra hora local;
- al volver después de 10 minutos, resincroniza `AppTime`;
- al volver después de 60 minutos, reinicia el flujo desde `SplashScreen`.

## Fuera de alcance de este checkpoint

Todavía no se modifica la dependencia arquitectónica donde:

- `core/services/offline_service.dart` conoce `features/ventas`;
- `core/services/realtime_sync_service.dart` conoce `features/almacen`.

Ese será el siguiente bloque una vez que este movimiento mecánico pase `flutter analyze` y `flutter test`.

## Validación requerida

```bash
flutter analyze
flutter test
```

Si ambos pasan, hacer smoke test mínimo:

1. inicio en Splash;
2. restauración de sesión;
3. login/logout;
4. cambiar tema claro/oscuro;
5. abrir `/home` normalmente;
6. cerrar/reabrir la app.
