# Fase 5 — Preparación de distribución móvil

Fecha de revisión: 2026-08-21

Este documento separa cambios técnicos seguros de decisiones que requieren identidad de aplicación o secretos privados. No contiene keystores, certificados ni contraseñas.

## iOS

### Corregido en Fase 5

`ios/Runner/Info.plist` ya declara:

- `NSCameraUsageDescription`;
- `NSPhotoLibraryUsageDescription`.

La app usa selección/captura de imágenes, por lo que estas descripciones son necesarias para evitar fallos o denegaciones al solicitar acceso en iOS.

La solicitud de permiso de notificaciones tampoco se dispara ya durante el bootstrap. OneSignal se configura de forma silenciosa y StOmni muestra primero una explicación de la utilidad de las alertas; solo al elegir `Activar notificaciones` se solicita el permiso del sistema. La explicación se recuerda localmente para no reaparecer automáticamente.

### Pendiente antes de distribución real

El proyecto todavía usa un Bundle ID basado en `com.example...` dentro del proyecto Xcode.

No se cambia automáticamente porque el Bundle ID debe:

- ser propiedad del desarrollador;
- coincidir con App ID/provisioning de Apple;
- conservarse estable para futuras actualizaciones;
- revisarse junto con la configuración de OneSignal/APNs.

También debe verificarse en macOS/Xcode:

- Team de desarrollo;
- Signing & Capabilities;
- Push Notifications si OneSignal seguirá habilitado;
- Background Modes / Remote notifications cuando corresponda;
- instalación real en iPhone.

## Android

### Corregido en Fase 5

`android/app/build.gradle.kts` ya no permite firmar un build Release con la clave debug.

La configuración ahora:

- lee `android/key.properties` únicamente si existe;
- crea `signingConfigs.release` con ese material privado;
- usa la firma Release únicamente cuando fue configurada;
- falla cerrado si se solicita una tarea `Release` sin `key.properties`;
- mantiene claves, contraseñas y archivos `.jks`/`.keystore` fuera de Git;
- incluye `android/key.properties.example` únicamente con placeholders seguros.

El mensaje de fallo deliberado es claro: un artefacto Release no se produce silenciosamente con la identidad criptográfica de debug.

También se limpió un carácter `\\` residual del template en `AndroidManifest.xml`. El nombre visible Android ya es `StOmni`.

### Pendiente antes de distribución real

El proyecto todavía mantiene:

- `applicationId = "com.example.ferreteria_app"`;
- `namespace = "com.example.ferreteria_app"`.

Antes de cambiar el Application ID debe definirse un identificador definitivo bajo un namespace controlado por el propietario. No se debe inventar uno automáticamente porque cambiarlo altera la identidad de la app y puede afectar:

- actualizaciones sobre instalaciones existentes;
- OneSignal;
- deep links/integraciones futuras;
- publicación en tiendas.

La keystore real también debe crearse/conservarse de forma privada fuera del repositorio. Fase 5 prepara el wiring, pero no genera ni versiona una clave privada.

Cierre Android cuando exista identidad/keystore:

1. definir Application ID definitivo;
2. actualizar `namespace`/`applicationId` y cualquier integración vinculada;
3. crear `android/key.properties` local/CI usando la plantilla;
4. verificar `flutter build appbundle --release` y APK Release;
5. instalar el Release en un dispositivo real;
6. comprobar una actualización sobre la misma firma antes de distribuir.

## Web/PWA

La identidad visible dejó de usar los placeholders del proyecto Flutter:

- `<title>StOmni</title>`;
- `apple-mobile-web-app-title = StOmni`;
- `manifest.json` usa `StOmni` como `name` y `short_name`;
- se retiró `A new Flutter project.` de la metadata visible.

La carga/preview de imágenes de productos también es multiplataforma: usa bytes (`readAsBytes`/`Uint8List`) y `uploadBinary`, sin depender de `dart:io File`.

## Versión

El Splash ya no contiene `Versión 2.0.0` hardcodeado.

La versión visible proviene de `PackageInfo.fromPlatform()` y muestra `version + buildNumber`, por lo que la fuente de verdad del build vuelve a ser la metadata de plataforma derivada de `pubspec.yaml`.

`pubspec.yaml` sigue declarando actualmente:

```yaml
version: 1.0.0+1
```

Ese valor puede aumentarse cuando se prepare la primera distribución real, pero no debe duplicarse manualmente en widgets.

## CI de distribución

El workflow Flutter quedó en modo de validación de solo lectura:

- `contents: read`;
- no reescribe fuentes;
- no crea commits;
- no hace `git push` desde CI;
- ejecuta Analyzer, tests y `flutter build web --release`.

Android Release no se agrega todavía al CI porque debe fallar cerrado mientras no exista una keystore privada/configuración de firma disponible como secreto de CI. Un Android debug build puede añadirse como smoke de Gradle sin debilitar esa regla.

## Estado

- permisos de privacidad iOS para imágenes: ✅;
- prompt contextual de notificaciones: ✅ código;
- identidad visible Web/PWA: ✅;
- firma Android Release con debug: ✅ eliminada;
- wiring de firma privada Android: ✅;
- Bundle ID iOS definitivo: ⏳ identidad/configuración Apple;
- Application ID Android definitivo: ⏳ decisión de identidad;
- keystore Android real: ⏳ secreto privado del propietario;
- APNs/entitlements iOS: ⏳ configuración Apple/OneSignal;
- versión visible dinámica: ✅;
- secretos/certificados versionados: ❌ ninguno añadido.
