# Actualizaciones QA para Android y Windows

La fuente de verdad sigue siendo StOmni_App privado. El mirror público solo valida,
compila y publica **metadatos de versión sin instaladores**, nunca binarios ni tokens.

## Flujo

1. Validación CI → APK Android firmado y setup Windows → Releases del original
   privado. La pre-release solo se publica después de verificar tamaño y SHA256.
2. Una vez publicada la pre-release, el mismo workflow usa su GITHUB_TOKEN
   efímero y el permiso **Contents: write limitado al job installers** para
   publicar un JSON muy pequeño en la rama independiente `qa-update-feed`
   del espejo CI (archivo `latest.json`). No contiene secretos, URLs con
   credenciales ni instaladores.
3. Al abrir Home de Android o escritorio Windows, se consulta ese JSON con un
   timeout de ocho segundos. Los errores de red no afectan el trabajo offline.
4. Se compara el `build_number` con la versión instalada (PackageInfo).
   Se notifica solo si hay un build posterior y un asset del tipo correcto.
5. El botón abre una URL fija del repositorio **privado** en el navegador.
   Se requiere iniciar sesión en GitHub con permisos sobre StOmni_App y
   descargar el APK o el setup EXE. La instalación es explícita, nunca silenciosa.

El usuario puede descartar el aviso hasta la siguiente apertura de Home.
El instalador de Windows mantiene el mismo AppId; Android debe conservar el
mismo packageName y keystore para instalar por encima y retener datos.

## Seguridad y privacidad

- No incrustar PAT, `service_role`, claves de firma, contraseñas ni claves API privadas
  en aplicaciones o feed.
- El cliente valida estructura, producto, versión, assets y etiqueta de publicación
  antes de construir él mismo una URL a `github.com/fernando15xvs/StOmni_App`.
- El feed público revela el número de build y el nombre de release de desarrollo,
  no acceso al archivo ni al código privado.
- El branch del feed es producto del proceso CI, no desarrollo de código.
- El pipeline no cambia Supabase remoto.
- Las futuras versiones de escritorio y móvil conservan interfaces separadas
  y su propia descarga. No se hace actualización silenciosa ni instalación remota.
- Si el job `installers` falla al publicar el feed después de subir el release,
  la release privada puede existir mientras el feed anterior permanece: investigar
  permisos del GITHUB_TOKEN y reintentar solo después de comprobar versiones.

## Comprobación manual

1. Instalar build QA N en Android y Windows, conservar datos locales.
2. Publicar un build N+1 con validación 7/7.
3. Abrir Home y confirmar que aparece el aviso de la plataforma correcta.
4. Abrir el enlace, autenticar en GitHub, descargar e instalar la actualización.
5. Reiniciar y confirmar que deja de aparecer el aviso y que los datos sobreviven.
6. Probar sin conexión: Home permanece utilizable y no aparece un bloqueo.
