# Instaladores de desarrollo: Android y Windows

Decisión del propietario, 2026-10-17:

- Fuente original privada: `fernando15xvs/StOmni_App`.
- Rama SaaS: `feature/saas-multitenant-foundation`.
- Ejecutar Actions exclusivamente en `fernando15xvs/StOmni_App_CI`.
- Publicar APK y setup EXE exclusivamente en **Releases del original privado**.
- Backend QA: `https://iqooedpkihmzkmynsisl.supabase.co` (`StOmniApp`).
- `App_StOmni_M` es otro producto. No sincronizarlo ni usar su backend/firma.

## Acceso a las descargas

Abrir https://github.com/fernando15xvs/StOmni_App/releases con una cuenta que
tenga acceso al repositorio privado y elegir una pre-release **StOmni SaaS QA**.
Descargar el `.apk` para Android o el `windows-x64-setup.exe` para Windows.
Se incluyen SHA-256 y certificado público de firma Android.

Este documento configura el flujo; no afirma que ya exista una release publicada.
Las pre-releases son para QA y no constituyen el GO comercial del runbook.

## Preparación única en Settings → Secrets and variables → Actions del CI

Crear estos Repository secrets, nunca en archivos versionados:

| Secret | Contenido |
| --- | --- |
| `STOMNI_QA_PUBLISHABLE_KEY` | Clave `sb_publishable_...` de StOmniApp QA |
| `STOMNI_ANDROID_KEYSTORE_BASE64` | JKS de firma Android codificado en Base64 |
| `STOMNI_ANDROID_STORE_PASSWORD` | Contraseña aleatoria, caracteres hexadecimales |
| `STOMNI_ANDROID_KEY_PASSWORD` | Contraseña de la clave, caracteres hexadecimales |
| `STOMNI_ANDROID_KEY_ALIAS` | `stomni-saas-qa` |
| `STOMNI_SOURCE_RELEASE_TOKEN` | Token de alcance restringido al original, Contents read/write |

El `GITHUB_TOKEN` del espejo no puede publicar en el original privado.
El token de publicación debe tener fecha de caducidad y acceso sólo a
`fernando15xvs/StOmni_App`; no necesita permisos de administración ni Actions.
Conservar un respaldo seguro del JKS y contraseñas. No rotar esa firma en cada build.
Nunca usar `service_role`, claves secretas de Supabase o claves del otro producto.

## Ejecución

1. Sincronizar el candidato fuente al espejo con el script habitual.
2. Actualizar **sólo en CI** `.github/saas-installers-trigger` con el SHA fuente
   y la fecha UTC; hacer commit y push en la rama SaaS.
3. El workflow `StOmni QA installers to private source` valida configuración y
   correspondencia completa de blobs/modos del espejo con el SHA original.
4. Ejecuta como workflow reutilizable `StOmni SaaS Full Validation` sobre el
   mismo commit CI. Conserva sus siete jobs y pruebas, pero ya no sube APK/Windows
   como artifacts públicos. No transmite secretos de firma a esas pruebas.
5. Sólo con validación verde, compila Android release y Windows release contra QA.
6. Empaqueta Windows con Inno Setup 6 y DLLs redistribuibles de MSVC; prueba
   instalación silenciosa, actualización y desinstalación en el runner desechable.
7. Crea una release **draft** en el original, sube ambos instaladores y verifica
   tamaño y digest SHA-256 devuelto por GitHub. Sólo después publica la pre-release.

El disparador por push evita tener que modificar `main` para registrar el botón
manual de GitHub. `workflow_dispatch` también se admite cuando GitHub lo exponga.
Nunca ejecutar este workflow desde el original; el guard de repositorio lo bloquea.
El sincronizador no conserva el disparador de instaladores: cada entrega requiere
un cambio explícito nuevo en el espejo. No añadir ese disparador al original.

## Identidad y versiones

- Android QA: `com.stomni.saas.qa`, independiente de StOmni M.
- Namespace Kotlin sin cambios.
- Windows QA: AppId fijo `{F455C916-8664-42BB-B357-4C51DD97F282}`;
  instalación por usuario en `Programs/StOmni SaaS QA`.
- `versionName`: `2.0.1`; `versionCode`: `10000 + GITHUB_RUN_NUMBER`.
- Windows usa esa misma versión y número; se valida el límite de 65535.
- Un reintento conserva versión y genera una etiqueta con el número de intento.
- No borrar/recrear el workflow ni reiniciar su contador para entregas futuras.
- Windows no lleva firma Authenticode comercial: puede mostrar editor desconocido.
  No se simula confianza con un certificado autofirmado.

## Estado de verificación

Las pruebas Python cubren repositorio/rama/evento permitidos, proveniencia,
integridad del espejo, destino privado, conjunto completo de assets y fallo de
digest que conserva el borrador. La compilación real requiere los secretos anteriores.
Una compilación exitosa no certifica interacción física, login o aceptación L00–L08.

## Si falla

No publicar manualmente un borrador incompleto. Corregir primero en SOURCE,
sincronizar nuevamente y ejecutar las pruebas del nuevo candidato.
No desplegar migraciones ni Edge Functions como parte de este flujo.
Los artifacts históricos de CI no se eliminan automáticamente.
