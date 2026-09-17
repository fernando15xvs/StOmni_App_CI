# Auditoría — frontera de plataformas y futura interfaz Web dedicada

## Decisión

StOmni separa sus clientes por factor de forma y capacidades de plataforma:

- `packages/mobile_app`: **Android e iOS**;
- `packages/desktop_app`: **Windows, Linux y macOS**;
- navegador: **no soportado por el candidato SaaS actual**.

La experiencia Web se implementará más adelante como un cliente dedicado, previsto como `packages/web_app`. No se reutilizará `mobile_app` como producto Web sólo porque Flutter permita compilarlo para navegador.

## Evidencia que originó la decisión

Durante el smoke local L02 del candidato fuente `30e00b43bf8925591feece0fdbe17fec20109843` se ejecutó `mobile_app` en Chrome únicamente para validar el contrato que existía en ese momento.

Se observaron dos problemas independientes:

1. la presentación móvil se expandía al ancho del navegador y producía una experiencia visual equivalente a un teléfono sobredimensionado, no una interfaz Web diseñada para escritorio;
2. al entrar a Almacén, la ruta de inventario intentó usar `LocalDbService`/SQLite y falló en navegador con `databaseFactory not initialized`, evidenciando que la infraestructura local del cliente móvil no tiene un contrato Web válido.

El login, alta de organización y acceso al dashboard multi-tenant sí funcionaron antes de alcanzar la ruta incompatible. Por tanto, el hallazgo no invalida por sí mismo Auth/RLS/tenant; invalida la decisión anterior de tratar `mobile_app` como producto Web soportado.

## Corrección arquitectónica aplicada

Se adopta la siguiente frontera:

```text
packages/
├── core_logic/    # reglas y casos de uso reutilizables
├── mobile_app/    # Android / iOS
├── desktop_app/   # Windows / Linux / macOS
└── web_app/       # futuro; todavía no existe
```

Como consecuencia:

- se elimina `packages/mobile_app/web/`;
- CI deja de ejecutar `flutter build web` sobre `mobile_app`;
- T15/L02 dejan de exigir navegador para este candidato;
- CI incorpora un gate que impide reintroducir accidentalmente `mobile_app/web`;
- el fallo SQLite observado no se parchea dentro de `mobile_app`, porque Web ya no es una plataforma de ese cliente.

## Contrato para la futura `web_app`

Cuando se abra la fase Web, no bastará con copiar la UI móvil. El cliente deberá tener una interfaz diseñada para navegador, preferentemente desktop-first y responsive, con navegación y densidad de información propias del entorno Web.

La futura implementación deberá:

1. reutilizar `packages/core_logic` para reglas de negocio, autorización y casos de uso que sean realmente agnósticos de plataforma;
2. definir adaptadores Web para persistencia/cache sin depender de SQLite móvil/FFI;
3. mantener el mismo contrato SaaS de tenant derivado server-side, RLS, RPC, Edge y Storage;
4. implementar login, onboarding, cambio ORG_A → ORG_B, branding, logout y limpieza de cache con pruebas específicas de navegador;
5. diseñar dashboard, tablas, formularios y navegación para resoluciones de escritorio/tablet, sin estirar widgets móviles;
6. incorporar accesibilidad, teclado, navegación por URL, refresh/deep links y comportamiento de múltiples pestañas donde aplique;
7. añadir `flutter analyze`, `flutter test`, build Web release y smoke/E2E de navegador propios a CI;
8. actualizar T13–T16 y el plan de release antes de declarar Web como plataforma soportada.

## Fuera de alcance de esta corrección

Esta decisión **no crea `web_app` ahora** y no autoriza a omitir pruebas de una plataforma ya declarada como soportada. Sólo redefine explícitamente el conjunto soportado del candidato actual antes de generar un nuevo candidato CI.

Tampoco modifica `main`, no hace merge, no despliega y no aplica migraciones al Supabase remoto.

## Regla de reapertura

Web sólo volverá a aparecer como plataforma exigible cuando exista una fase/roadmap dedicada que incluya, como mínimo:

- paquete `packages/web_app` versionado;
- arquitectura de presentación Web aprobada;
- almacenamiento/cache compatible con navegador;
- gates de seguridad y multi-tenant;
- build release Web en CI;
- smoke de navegador real;
- regresión funcional ORG_A/ORG_B;
- actualización explícita de `99_MAPA_MAESTRO_PRUEBAS_SAAS.md` y `100_PLAN_VALIDACION_GITHUB_ACTIONS_Y_LOCAL.md`.

Hasta entonces, intentar ejecutar `mobile_app` con Chrome no constituye una superficie soportada ni evidencia válida de release.
