# StOmni App — SaaS (desarrollo)

Aplicación de gestión comercial multiempresa con **dos interfaces Flutter independientes** que comparten lógica de negocio y backend Supabase.

| Interfaz | Paquete | Plataformas |
| --- | --- | --- |
| Móvil | `packages/mobile_app` | Android e iOS |
| Escritorio | `packages/desktop_app` | Windows, Linux y macOS |
| Lógica compartida | `packages/core_logic` | Modelos, servicios y reglas reutilizados por ambos clientes |

**No hay un cliente web publicable actualmente**. Una futura interfaz web se desarrollaría por separado; no se debe compilar la interfaz móvil como sitio web.

## Descargar instaladores de pruebas

[**Releases de StOmni App (repositorio privado)**](https://github.com/fernando15xvs/StOmni_App/releases)

Cuando se complete la primera publicación QA, allí estarán:

- **Android:** APK firmado, generado desde la interfaz de `mobile_app`.
- **Windows:** instalador `.exe` (x64), generado desde la interfaz de `desktop_app`.
- Sumas SHA-256 e información pública de la firma Android.

Se requiere acceso al repositorio privado. Una compilación de CI aprobada **no** significa que los instaladores ya estén publicados. Por ahora el objetivo son instaladores de desarrollo, no lanzamientos comerciales.

[Guía de compilación y publicación QA](docs/saas/104_INSTALADORES_QA_GITHUB.md).

## Repositorios y validación

- **Fuente de verdad:** `fernando15xvs/StOmni_App`, rama `feature/saas-multitenant-foundation`.
- **Espejo para GitHub Actions:** `fernando15xvs/StOmni_App_CI`, rama con el mismo nombre.
- No desarrollar directamente en el espejo. No ejecutar Actions en el original.
- Las pruebas y compilaciones se ejecutan en el espejo; los instaladores se publican **exclusivamente** en Releases del original.
- Backend de pruebas: proyecto Supabase `StOmniApp`, ref `iqooedpkihmzkmynsisl`. No confundir QA con producción.

## Ejecutar durante el desarrollo

Instalar Flutter compatible con el proyecto y obtener las dependencias desde la raíz:

```bash
flutter pub get
```

Luego, desde el paquete correspondiente, ejecutar Flutter en el destino elegido:

```bash
cd packages/mobile_app
flutter run -d <dispositivo-android-o-ios> --dart-define=SUPABASE_URL=<url-qa> --dart-define=SUPABASE_ANON_KEY=<clave-publicable-qa>
```

Para escritorio, regresar a la raíz y cambiar al paquete `packages/desktop_app`:

```bash
flutter run -d windows --dart-define=SUPABASE_URL=<url-qa> --dart-define=SUPABASE_ANON_KEY=<clave-publicable-qa>
```

Los valores deben proceder del entorno de QA. No añadir contraseñas, claves privadas, `service_role` ni archivos de firma al repositorio.

## Documentación

- [Auditoría de continuidad QA](docs/saas/103_AUDITORIA_MAESTRA_CONTINUIDAD_QA_20260929.md)
- [Mapa maestro de pruebas](docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md)
- [Separación de clientes y límites de plataformas](docs/saas/101_AUDITORIA_FRONTERA_PLATAFORMAS_Y_WEB_FUTURA.md)
- [Instaladores de desarrollo](docs/saas/104_INSTALADORES_QA_GITHUB.md)

No desplegar migraciones ni Edge Functions desde el flujo de compilación de instaladores.
