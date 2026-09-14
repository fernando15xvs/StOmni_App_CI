# Fase 8.4 — Branding por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Commit de cierre técnico:

- `000f1171cda2f70a6f9c20bf7a861454c83b677f`

Gate:

- `scripts/verify_saas_business_branding.mjs`

Pruebas:

- `packages/core_logic/test/business/business_branding_test.dart`;
- `packages/core_logic/test/architecture/business_branding_boundary_test.dart`;
- `packages/core_logic/test/pdf_renderers_test.dart`;
- `supabase/tests/database/business_branding_contract_test.sql`.

## Objetivo

Mostrar la identidad de la empresa autenticada de forma coherente en mobile,
Web, Desktop y documentos, sin crear una segunda fuente de nombre o logo y sin
permitir que el cliente seleccione el tenant.

## Fuente autoritativa reutilizada

No se creó una tabla de branding.

La fuente continúa siendo `public.configuracion_negocio`, ya vinculada a
`organization_id` por F3.1:

- `nombre_comercial` define el nombre visible;
- `razon_social` es el fallback legal;
- `logo_url` referencia el logo;
- `organization_id` identifica el tenant devuelto por backend.

La lectura reutiliza `get_current_business_configuration_v1()`. La RPC no
acepta parámetros, deriva el tenant con
`private.require_current_organization_id()`, exige `tenant.read` y filtra
`configuracion_negocio` por la organización autenticada.

F8.4 no añade migración ni RPC. El nuevo pgTAP inspecciona dinámicamente el
contrato existente, sus privilegios y la policy de escritura de logos.

## Contrato compartido

Se añadieron bajo `packages/core_logic/lib/business/`:

- `BusinessBranding`;
- `CachedBusinessBranding`;
- `BusinessBrandingGateway`;
- `BusinessBrandingMapper`;
- `SupabaseBusinessBrandingGateway`;
- providers Riverpod auto-dispose.

El contrato contiene únicamente identidad visual derivada de la configuración
real: organización, nombre comercial, razón social y URL del logo. El nombre
visible aplica esta secuencia determinista:

1. `nombre_comercial`;
2. `razon_social`;
3. `StOmni` como fallback neutral de producto.

## Aislamiento tenant y offline

El gateway:

- no recibe `organization_id`;
- no consulta `configuracion_negocio` directamente;
- comprueba que el usuario Auth no cambie durante la lectura;
- valida el UUID de organización incluido en la respuesta;
- guarda snapshots con namespace de backend y usuario Auth;
- sólo permite fallback offline ante un error de conectividad reconocido;
- limita el snapshot visual a 24 horas y tolera como máximo 5 minutos de sesgo
  futuro;
- nunca convierte el branding cacheado en autorización.

El provider es `autoDispose`, por lo que un shell desmontado no conserva el
branding observado para la siguiente sesión.

Además, `ConfiguracionService` ahora liga su snapshot fiscal/visual estático al
`auth.currentUser.id`. `AuthController` llama a
`clearActiveConfiguration()` al iniciar una autenticación nueva, al cerrar
sesión y al aplicar estados que retiran autorización. Así un cambio
ORG_A -> ORG_B dentro del mismo proceso no puede reutilizar el logo o perfil
fiscal de ORG_A en un PDF de ORG_B.

## Mobile y Web

`DashboardTab` consume `businessBrandingProvider` y muestra nombre/logo en la
cabecera. Una URL ausente o fallida conserva un fallback visual neutro.

La misma pantalla Flutter cubre Web. No se introdujeron `dart:io` ni APIs de
plataforma en el renderizado de marca.

`ConfiguracionNegocioPage` continúa editando la fuente autoritativa existente,
invalida el provider después de una escritura confirmada y limita el formulario
a 840 px en superficies amplias para teléfono, tablet y navegador.

## Desktop

`DesktopHomeShell` usa el mismo provider compartido. Presenta el logo y nombre
de la empresa en el rail y el nombre en la barra superior. En una autorización
offline válida solicita exclusivamente el snapshot visual local; un fallo de
branding no bloquea el Home ni amplía permisos.

## PDFs y documentos

Los renderizadores de cotización y ticket ya recibían `PdfBranding`; F8.4
completa la semántica visual:

- encabezado principal con nombre comercial;
- razón social adicional cuando difiere;
- logo de la configuración tenant actual;
- fallback al asset neutral cuando el logo remoto no está disponible.

`PdfBrandingLoader` sólo acepta HTTPS o HTTP loopback para Supabase local,
comprueba `Content-Type: image/*` y no entrega al renderizador imágenes mayores
de 5 MiB. Esquemas como `file:` y `data:`, además de HTTP remoto, se rechazan.

## Storage

Se conserva la infraestructura F3.1:

```text
<organization_uuid>/logos/<archivo>
```

Las policies de `storage.objects` vuelven a comprobar el primer segmento contra
`private.current_organization_id()` y exigen `tenant.admin` para insertar,
actualizar o eliminar. F8.4 no relaja esas policies ni introduce service-role en
clientes.

## Gate y evidencia ejecutada

El gate F8.4 comprueba:

- fuente autoritativa y RPC tenant-aware existentes;
- ausencia de `organization_id` manipulable o lectura directa de tabla;
- contrato/provider compartidos y caché aislada;
- consumo de nombre/logo en mobile/Web y Desktop;
- formulario responsive e invalidación posterior al guardado;
- limpieza de snapshots en fronteras Auth;
- branding de PDFs y validación del logo;
- existencia de pruebas Dart y pgTAP.

Evidencia del cierre técnico:

```text
node scripts/verify_saas_business_branding.mjs --self-test
SaaS business branding self-test OK (5 límites).

node scripts/verify_saas_business_branding.mjs
SaaS business branding gate OK (F8.4).

node scripts/verify_saas_domain_configuration.mjs --self-test
SaaS domain configuration self-test OK (5 contratos/casos).

node scripts/verify_saas_domain_configuration.mjs
SaaS domain configuration gate OK (Fase 3.1).

node scripts/verify_saas_onboarding_ux.mjs --self-test
SaaS onboarding UX self-test OK (4 límites).

node scripts/verify_saas_onboarding_ux.mjs
SaaS onboarding UX gate OK (F8.3).

node scripts/verify_saas_rpc_surface.mjs --self-test
SaaS RPC self-test OK (4 casos).

Dart lexical delimiter check OK (60 archivos del workspace parcial).
```

Los 21 blobs del commit técnico se compararon con los archivos auditados y
coinciden exactamente.

## Validación dinámica pendiente

Este entorno no dispone de `dart`, `flutter` ni Supabase CLI. Por tanto, siguen
pendientes para T03/T04/T11/T13/T14/T15:

- reset de Supabase local y ejecución de pgTAP;
- formato y análisis Flutter;
- suites unit/widget completas;
- ORG_A/ORG_B con nombres y logos distintos;
- logout A -> login B sin branding ni perfil fiscal residual;
- restauración offline con snapshot visual del usuario correcto;
- render real en teléfono, tablet, Web y Desktop;
- cotización/ticket con logo, nombre comercial y razón social;
- builds y smoke tests declarados por plataforma.

No se marca `GATE BLOQUE 8 VERDE` por la evidencia estática de esta fase.

## Resultado

F8.4 queda cerrada a nivel de implementación sin duplicar identidad empresarial:
mobile, Web, Desktop y PDFs consumen branding derivado de la configuración del
tenant autenticado, con aislamiento de sesión y fallback offline acotado. La
certificación dinámica permanece abierta hasta ejecutar el mapa T00–T19.
