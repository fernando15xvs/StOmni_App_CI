# Fase 8.3 — UX mobile / desktop / web

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Commit de cierre técnico:

- `677fb05f404cb9477e7667938cacafd0ee5786bd`

Gate:

- `scripts/verify_saas_onboarding_ux.mjs`

Pruebas Dart:

- `packages/core_logic/test/auth/validate_session_use_case_test.dart`;
- `packages/core_logic/test/onboarding/saas_entry_routing_policy_test.dart`;
- `packages/core_logic/test/auth/operation_authorizer_test.dart`.

F8.3 no añade tablas, migraciones ni RPC. Por tanto, no crea un pgTAP nuevo:
reutiliza los contratos de F8.1/F8.2 y añade pruebas Dart para la política de
sesión/routing que pertenece al cliente compartido.

## Objetivo

Cerrar el recorrido SaaS posterior a Auth en todas las presentaciones:

```text
sesión Auth
  -> cambio obligatorio de contraseña
  -> alta de empresa si aún no existe tenant
  -> configuración guiada si está incompleta
  -> Home si está completa
```

Una autorización offline tenant válida conserva un recorrido independiente:

```text
autorización offline vigente -> Home offline
```

Nunca consulta onboarding remoto ni habilita la creación de una empresa sin
conexión.

## Política compartida

Se creó:

- `onboarding/application/saas_entry_routing_policy.dart`.

`SaasEntryRoutingPolicy` es la única matriz de decisión consumida por mobile,
Web y Desktop. Modela:

- `signedOut`;
- `passwordChangeRequired`;
- `organizationSetupRequired`;
- `onboardingRequired`;
- `authorized`;
- `offlineAuthorized`.

El estado visual `checking` sigue siendo responsabilidad de cada shell, pero no
contiene decisiones de autorización.

La política sólo abre Home en dos casos:

- sesión online con onboarding confirmado como completado;
- autorización offline tenant válida.

## Sesión Auth pre-tenant

`organizationSetupRequired` permanece fuera de `isAuthorized`.

Además, `ValidateSessionUseCase` ahora elimina cualquier snapshot offline
operativo inmediatamente después de que el backend confirme que la identidad
no tiene un rol tenant activo. Sólo después consulta la elegibilidad F8.1.

Si esa segunda consulta queda sin conexión:

- Auth puede permanecer para reintentar;
- no se devuelve estado offline;
- no se reutiliza el snapshot retirado;
- no se entra a Home ni se autoriza una operación empresarial.

Esto cierra la ventana en la que una autorización antigua podía sobrevivir a
una clasificación online pre-tenant.

## Estado compartido de Auth

`AuthState` conserva `SessionValidationStatus` como fuente de verdad y deriva de
él los flags de compatibilidad para contraseña y alta.

`signIn()` y `restoreSession()` continúan usando `ValidateSessionUseCase`; no se
introdujo una segunda consulta manual de `app_users`, roles o tenant dentro del
login.

Después de `create_my_organization_v1`, ambas presentaciones llaman a
`finishOrganizationSetup()`. Esta revalidación:

- deshabilita fallback offline;
- exige resultado `online`;
- exige `isAuthorized` tenant;
- sólo entonces permite avanzar a onboarding.

Si la creación terminó pero la revalidación sufrió una caída transitoria, la UI
conserva el estado local de “empresa creada” y permite revalidar sin intentar un
segundo alta.

## Mobile y Web

La misma aplicación Flutter cubre Android, iOS y navegador.

Se completaron:

- `login_page.dart`: usa la política compartida después de `signIn()`;
- `splash_screen.dart`: restaura contraseña, alta, onboarding, Home online y
  Home offline según el estado;
- `saas_entry_gate.dart`: consulta F8.2 sólo para sesiones online tenant;
- `organization_setup_page.dart`: alta responsive mediante el caso de uso F8.1;
- `guided_onboarding_page.dart`: avance secuencial con `nextStep` y `revision`
  autoritativos.

Las pantallas de onboarding usan `LayoutBuilder`, no importan `dart:io`, no
dependen de APIs Android/iOS y no reciben `organization_id`.

## Desktop

`DesktopAuthGate` conserva un `SessionValidationStatus` explícito y aplica la
misma `SaasEntryRoutingPolicy`.

Se cubren:

- sesión cerrada -> login;
- contraseña obligatoria -> `DesktopPasswordChangeView`;
- pre-tenant -> `DesktopOrganizationSetupView`;
- onboarding incompleto -> `DesktopGuidedOnboardingView`;
- online completo -> `DesktopHomeShell`;
- offline tenant válido -> `DesktopHomeShell` en modo offline.

El cambio de contraseña no navega directamente a Home: vuelve a ejecutar la
validación compartida y el gate decide si corresponde alta, onboarding o Home.

## Aislamiento de estado entre sesiones

Los providers de progreso guiado y elegibilidad de alta pasaron a
`FutureProvider.autoDispose`.

Así, un logout de ORG_A seguido por login de ORG_B en el mismo proceso no puede
reutilizar el progreso de onboarding observado para ORG_A.

## Seguridad de la frontera cliente

- ninguna pantalla recibe o construye `organization_id`;
- ninguna pantalla recibe o selecciona `plan_code`;
- no existe llamada cliente a `bootstrap_organization_v1`;
- el adaptador conserva la llamada literal a `create_my_organization_v1`;
- un usuario pre-tenant no obtiene rol, permisos ni cache offline;
- onboarding incompleto no abre Home;
- modo offline no intenta crear tenant ni consultar progreso remoto.

No se añadieron RPC, por lo que `verify_saas_rpc_surface.mjs` no requiere una
clasificación nueva. Las RPC consumidas siguen cubiertas por los gates F8.1 y
F8.2.

## Gate y pruebas

`verify_saas_onboarding_ux.mjs` comprueba estáticamente:

- estado pre-tenant fuera de `isAuthorized`;
- retiro del cache offline antes de clasificar alta;
- política de routing única;
- cambio de contraseña en login/splash/desktop;
- alta y onboarding en mobile/Web/Desktop;
- Home bloqueado mientras onboarding está incompleto;
- Home offline sin consulta F8.2;
- providers de onboarding no persistentes entre sesiones;
- ausencia de IDs tenant manipulables;
- ausencia de acceso cliente al bootstrap técnico;
- uso de `create_my_organization_v1` y revalidación online.

Evidencia ejecutada durante el cierre:

```text
node scripts/verify_saas_onboarding_ux.mjs --self-test
SaaS onboarding UX self-test OK (4 límites).

node scripts/verify_saas_onboarding_ux.mjs
SaaS onboarding UX gate OK (F8.3).
```

También se verificó que los 18 blobs publicados en el commit coinciden con los
archivos auditados localmente y que los delimitadores léxicos Dart están
balanceados.

## Validación dinámica pendiente

T13/T14/T15 deberán ejecutar sobre el commit candidato final:

- `dart format --output=none --set-exit-if-changed packages`;
- `flutter analyze` en los tres paquetes;
- `flutter test` en los tres paquetes;
- widget/integration tests del recorrido completo;
- login/Auth sin tenant -> alta -> onboarding -> Home;
- restauración con cambio obligatorio de contraseña;
- logout ORG_A -> login ORG_B sin progreso reutilizado;
- arranque offline tenant válido -> Home sin llamada de onboarding;
- mobile, Web y Desktop con tamaños reales;
- builds y smoke tests de las plataformas declaradas.

No se marca ningún gate dinámico del Bloque 8 por esta evidencia estática.

## Resultado

F8.3 queda cerrada a nivel de implementación con routing SaaS compartido,
presentaciones para mobile/Web/Desktop y frontera pre-tenant fail-closed. La
certificación dinámica permanece deliberadamente abierta hasta T00–T19.
