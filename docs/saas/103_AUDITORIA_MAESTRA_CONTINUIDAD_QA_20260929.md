# Auditoría maestra de continuidad — StOmni SaaS / QA remota

Fecha de consolidación: 2026-09-29  
Repositorio SOURCE: `fernando15xvs/StOmni_App`  
Repositorio CI: `fernando15xvs/StOmni_App_CI`  
Rama única de trabajo: `feature/saas-multitenant-foundation`

> Este documento es el punto de entrada obligatorio para continuar el trabajo.
> No sustituye al mapa maestro ni al plan de validación: los resume, fija el
> estado real alcanzado y explica qué evidencia sigue siendo válida.

---

## 1. Objetivo de esta auditoría

El objetivo es permitir que otra IA continúe sin reconstruir el contexto desde
cero, sin repetir trabajo ya validado y sin confundir pruebas históricas con
evidencia vigente.

La fase actual no es una implementación nueva del roadmap SaaS. El trabajo
inmediato es:

1. mantener un candidato reproducible y verde en CI;
2. usar una Supabase remota aislada como QA/Staging para acelerar pruebas
   manuales simultáneas de Desktop y Android;
3. corregir cualquier defecto real encontrado en esas pruebas;
4. cada cambio de código debe volver a SOURCE -> CI -> verde;
5. cuando el producto deje de producir fallos manuales, reiniciar la aceptación
   formal L00-L08 desde cero sobre el último SHA CI verde;
6. no declarar GO final hasta completar L08/T19.

---

## 2. Documentos que deben leerse antes de tocar código

Leer en este orden:

1. `docs/saas/103_AUDITORIA_MAESTRA_CONTINUIDAD_QA_20260929.md`
2. `docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md`
3. `docs/saas/100_PLAN_VALIDACION_GITHUB_ACTIONS_Y_LOCAL.md`
4. `docs/saas/102_CONTRATO_CANONICO_PRODUCTOS.md`
5. `docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md`
6. `docs/PLAN_LOCAL_MULTIPLATAFORMA.md`

Después revisar, según el problema a tratar:

- `packages/desktop_app/lib/features/home/desktop_home_shell.dart`
- `packages/desktop_app/test/widget_test.dart`
- `packages/core_logic/lib/features/almacen/data/local_db_service.dart`
- `packages/core_logic/test/features/almacen/local_db_service_upgrade_test.dart`
- `scripts/verify_saas_generic_catalog.mjs`
- `supabase/migrations/20260922173000_canonical_product_sale_contract.sql`
- `supabase/tests/database/canonical_product_sale_contract_test.sql`

En el repo CI revisar también:

- `docs/saas/CI_CANDIDATE_SOURCE.json`

Nunca empezar una corrección sólo con este documento. El mapa 99 define T00-T19
y el plan 100 define la relación entre CI y L00-L08.

---

## 3. Reglas operativas vigentes

### 3.1 Git

Trabajar únicamente en:

`feature/saas-multitenant-foundation`

Reglas:

- NO tocar `main`.
- NO hacer merge.
- NO hacer deploy a producción.
- Toda corrección de código se hace primero en SOURCE.
- Después se sincroniza el candidato al repositorio CI.
- No reutilizar un CI verde de un SHA anterior después de modificar SOURCE.
- No declarar una prueba dinámica como PASS si no existe evidencia de ejecución.
- No reescribir migraciones históricas para corregir estado final.
- Un cambio nuevo de esquema debe ser una nueva migración, salvo que se esté
  corrigiendo un defecto de código local que no sea parte del ledger PostgreSQL.

### 3.2 Supabase

La prohibición histórica de tocar Supabase remoto se mantiene para producción.

Existe una excepción autorizada explícitamente para QA:

- proyecto QA: `StOmniApp`
- project ref: `iqooedpkihmzkmynsisl`
- URL: `https://iqooedpkihmzkmynsisl.supabase.co`
- región observada: `sa-east-1`

Este proyecto es una base nueva/de pruebas y el usuario autorizó usarla
normalmente como QA/Staging.

En QA está permitido:

- probar Desktop y Android simultáneamente;
- aplicar cambios backend necesarios para reproducir el candidato;
- crear datos sintéticos;
- probar RLS/RPC/Storage/tenant;
- resetear o limpiar datos QA si la prueba lo exige y se confirma que sigue
  siendo el proyecto de QA.

No convertir esa autorización en permiso para producción.

No poner `service_role` en Flutter ni en archivos versionados.

---

## 4. Candidato funcional validado antes de este documento

El último candidato funcional confirmado totalmente verde antes de crear esta
auditoría fue:

SOURCE:

`cdbb23b837b2aaf7aa990092a0cefe458b52ffea`

CI mirror:

`1f11318f0a3ff97bac4d1a3c106f014e61b758fe`

GitHub Actions:

- run ID: `36273156524`
- conclusión: `success`

Jobs verificados:

- `T00-T02 static gates` — success
- `Automated backend validation` — success
- `Flutter core/mobile + Android` — success
- `Windows desktop validation` — success
- `Linux desktop compile smoke` — success
- `macOS/iOS compile smoke` — success
- `CI candidate summary` — success

Importante: la creación de este archivo documental hará avanzar el HEAD de
SOURCE. Por eso, al retomar, obtener siempre el HEAD actual de la rama y el
manifest CI. Si el único cambio posterior a `cdbb23b...` es documentación, la
implementación funcional sigue siendo la misma; aun así, para una aceptación
formal se usa el SHA exacto que haya pasado CI.

---

## 5. Qué ocurrió durante L00-L02 y por qué no se puede reutilizar esa evidencia

### 5.1 Primera ronda

Se inició la aceptación formal sobre el candidato anterior:

`05f34410628d7d351248b68dafedf5372e2a6f7c`

L00:

- inicialmente falló porque la copia local estaba 14 commits detrás;
- había archivos generados Flutter modificados;
- se guardaron en stash como respaldo;
- se hizo `git pull --ff-only`;
- SOURCE local/remoto quedó exactamente en `05f344...`;
- working tree quedó limpio;
- toolchain verificado:
  - Flutter 3.38.9
  - Dart 3.10.8
  - Supabase CLI 2.109.1
  - PostgreSQL 17.11
  - Docker 29.7.2
  - Android SDK 36.1.0
  - Visual Studio disponible
- L00 terminó PASS.

L01:

- Supabase local arrancó;
- `supabase db reset` local reconstruyó las migraciones;
- working tree siguió limpio;
- L01 terminó PASS.

### 5.2 L02 encontró defectos reales

En Android, el login llegó correctamente al Home para ORG_B.

En Desktop, después del login la ventana quedó en blanco y Flutter repetía:

`Failed assertion: '!semantics.parentDataDirty': is not true.`

También apareció en Android, al abrir Almacén, un error SQLite local:

`DatabaseException(duplicate column name: unit_configuration ... ALTER TABLE productos ADD COLUMN unit_configuration TEXT)`

Esos defectos provocaron cambios de código posteriores.

Conclusión:

**L00 y L01 históricos NO cuentan como evidencia final para el candidato
actual.**

La regla del plan 100 es clara: si SOURCE cambia, se obtiene un nuevo candidato,
se exige CI verde y la aceptación local L00-L08 se reinicia desde cero.

No marcar L00/L01/L02 del candidato actual usando esas ejecuciones anteriores.

---

## 6. Corrección del pantallazo blanco / Semantics en Desktop

### 6.1 Diagnóstico

El cambio anterior contra overflow había envuelto el `NavigationRail` completo
en un `SingleChildScrollView`.

El fallo dinámico aparecía después del login, cuando el shell cargaba branding y
destinos dinámicos.

### 6.2 Corrección

Archivo:

`packages/desktop_app/lib/features/home/desktop_home_shell.dart`

Se retiró el patrón de `NavigationRail` completo dentro de un scroll.

Se introdujo un sidebar desktop con:

- ancho controlado;
- branding/cabecera fija;
- lista de destinos en `ListView`;
- selección mediante `ListTile`;
- claves estables por destino/índice;
- contenido principal independiente.

Objetivo:

- evitar overflow vertical;
- evitar el conflicto de Semantics observado;
- seguir soportando muchos destinos en ventanas de poca altura.

### 6.3 Regresión automatizada

Archivo:

`packages/desktop_app/test/widget_test.dart`

Se añadió prueba que:

- fija una superficie baja;
- crea muchos destinos;
- renderiza el sidebar;
- comprueba que no hay excepción;
- hace scroll hasta el último destino;
- comprueba que sigue sin excepciones.

La validación Windows del candidato `cdbb23b...` pasó analyze, tests y build.

---

## 7. Corrección SQLite mobile: duplicate column unit_configuration

### 7.1 Diagnóstico

El error no era PostgreSQL/Supabase.

Era SQLite local del cliente móvil.

Archivo:

`packages/core_logic/lib/features/almacen/data/local_db_service.dart`

Una caché local podía encontrarse en un estado donde:

- la versión lógica exigía ejecutar una migración;
- pero la columna `unit_configuration` ya existía;
- el código intentaba ejecutar nuevamente:
  `ALTER TABLE productos ADD COLUMN unit_configuration TEXT`;
- SQLite devolvía `duplicate column name`.

El mismo patrón podía afectar `item_type` y `es_servicio`.

### 7.2 Corrección

Se añadió helper idempotente:

`_addColumnIfMissing(...)`

El helper:

1. consulta `PRAGMA table_info(tabla)`;
2. verifica si la columna ya existe;
3. retorna sin alterar la tabla si ya existe;
4. ejecuta el `ALTER TABLE` sólo cuando falta.

Las columnas protegidas incluyen:

- `unit_configuration`
- `item_type`
- `es_servicio`

### 7.3 Regresión automatizada

Archivo:

`packages/core_logic/test/features/almacen/local_db_service_upgrade_test.dart`

La prueba crea una DB SQLite legacy versión 8 donde
`unit_configuration` ya existe, abre `LocalDbService` y exige:

- upgrade a versión 10;
- exactamente una columna `unit_configuration`;
- presencia de `item_type`;
- presencia de `es_servicio`;
- ninguna excepción por columna duplicada.

### 7.4 Gate estático actualizado

Archivo:

`scripts/verify_saas_generic_catalog.mjs`

El gate anterior exigía literalmente los `ALTER TABLE` antiguos y por eso
rechazaba la corrección segura.

Se actualizó para exigir algo más fuerte:

- presencia del helper idempotente;
- lectura de `PRAGMA table_info`;
- comprobación del nombre de columna;
- retorno si existe;
- `ALTER TABLE` sólo si falta;
- definición exacta de `item_type`;
- definición exacta de `es_servicio`.

El self-test del gate incluye mutaciones negativas para demostrar que el gate
falla si se rompe la guarda de `item_type` o `es_servicio`.

El candidato final pasó T00-T02 y T13.

---

## 8. Contrato canónico de productos que no debe relajarse

Documento fuente:

`docs/saas/102_CONTRATO_CANONICO_PRODUCTOS.md`

Persistencia canónica de `tipo_venta`:

- `UNIDAD`
- `CAJA`
- `PAQUETE`
- `CAJA_PAQUETES`
- `CAJA_UNIDADES`

No aceptar como valores persistidos:

- `AMBOS`
- `SOLO_CAJAS`
- `SOLO_UNIDADES`
- `CAJA_UNIDAD`
- `CAJAS_UNIDADES`
- `PAQUETES`
- variantes lowercase
- variantes con whitespace que se normalicen silenciosamente

El perfil configurable de unidades es exclusivamente:

`schema_version: 2`

No reintroducir fallback runtime al schema v1.

El writer canónico es `save_product_unit_profile_v6`.

No volver a nombres legacy como:

- `LegacySaleLineMapper`
- `IntegerPresentationPolicy`
- `toLegacyMap()`
- `save_product_unit_profile_v1`

---

## 9. Estado de Supabase QA remota

Proyecto:

`https://iqooedpkihmzkmynsisl.supabase.co`

### 9.1 Migraciones

Antes de esta fase, QA llegaba sólo hasta:

`20260907003926_storage_buckets_and_policies`

Se aplicaron las 83 migraciones pendientes del repositorio, en orden, y se
registró su versión original en:

`supabase_migrations.schema_migrations`

No se creó un ledger paralelo ni versiones inventadas.

Estado verificado después:

- total de migraciones: 125
- última:
  `20260922173000_canonical_product_sale_contract`

Se verificó que existen, entre otros:

- `public.organizations`
- `public.app_users`
- `public.organization_subscriptions`
- `productos.organization_id`
- `create_my_organization_v1`

Nota importante:

`unit_configuration` NO es una columna PostgreSQL de `productos` en el
contrato final. El error del móvil era de SQLite local. No crear una columna
PostgreSQL con ese nombre para “arreglar” el error móvil.

### 9.2 Fixtures/tenants QA

Se prepararon dos tenants:

#### ORG_A

Display name:

`StOmni QA ORG_A`

Organization ID:

`217c3ed1-00b9-484f-8a1d-b33a317f0c47`

Usuario Auth existente:

`admin@stomni.com`

Estado verificado:

- membership: active
- base_role: admin
- empleado: admin y activo
- onboarding: completed
- pasos: business_profile, modules, operations, review
- plan observado: enterprise
- suscripción: active

ORG_A proviene del tenant legacy que la migración de bootstrap detectó y
normalizó.

#### ORG_B

Display name:

`StOmni QA ORG_B`

Organization ID:

`a2cdb987-aab5-4653-8e78-2ccfa8895f83`

Usuario Auth existente:

`user@stomni.com`

Estado verificado:

- membership: active
- base_role: admin
- empleado: admin y activo
- onboarding: completed
- pasos: business_profile, modules, operations, review
- plan observado: starter
- suscripción: active

ORG_B fue creada mediante el flujo SaaS soportado
`create_my_organization_v1`.

### 9.3 Contraseñas

No asumir ni inventar contraseñas.

El intento de modificar directamente contraseñas en `auth.users` fue
bloqueado por los controles de seguridad y no se forzó.

Si las credenciales existentes no son conocidas, restablecerlas mediante un
mecanismo Auth soportado para QA. No modificar `auth.users.encrypted_password`
manualmente como camino normal.

### 9.4 Edge Functions

El proyecto QA tiene 21 Edge Functions activas, todas observadas con
`verify_jwt=true`.

Nombres presentes:

- consultar-comprobante
- consultar-guia-remision
- consultar-nota-credito
- consultar-proceso-tributario
- create_employee
- delete_employee
- ejecutar-resumen-diario
- emitir-comprobante
- emitir-guia-remision
- emitir-nota-credito
- get-persona
- procesar-bajas-tributarias
- reintentar-comprobante
- reintentar-comprobantes-pendientes
- reintentar-guia-remision
- reintentar-guias-pendientes
- reintentar-nota-credito
- reintentar-notas-credito-pendientes
- reintentar-proceso-tributario
- reintentar-procesos-tributarios-pendientes
- resolver-resultado-incierto

Durante la alineación de QA descrita aquí **NO se hizo un redeploy completo de
esas Edge Functions desde el candidato actual**.

Por tanto:

- no asumir que su código remoto coincide byte a byte con SOURCE;
- antes de usar QA remota como evidencia de T10/L05/fiscal/empleados, comparar
  versión/código/configuración y, si hace falta, desplegar únicamente a QA;
- nunca trasladar ese permiso a producción;
- no poner secretos en logs ni en el cliente.

---

## 10. Qué CI ya cubre y qué no

El run verde `36273156524` prueba el candidato de código fuente con:

- gates estáticos;
- reconstrucción backend automatizada;
- pgTAP/contratos;
- DB lint y drift;
- E2E multi-tenant automatizado;
- T05-T09/T12/T14 automatizables;
- concurrencia;
- backup/restore;
- segunda reconstrucción;
- format/analyze/tests Flutter;
- build Android;
- build Windows;
- compile smoke Linux;
- compile smoke macOS/iOS.

CI NO reemplaza:

- interacción manual real;
- navegación humana completa;
- caché persistente de un dispositivo ya usado;
- cambio de tenant real en el mismo cliente;
- offline/reconexión;
- pruebas visuales;
- login/logout repetido;
- operación fiscal real contra integraciones externas de QA;
- push/OneSignal real;
- aceptación final T19.

---

## 11. Estrategia vigente: dos carriles de prueba

### Carril A — QA remota rápida

Objetivo:

encontrar y corregir bugs reales de frontend/backend sin resetear Supabase local
en cada iteración.

Usar:

`https://iqooedpkihmzkmynsisl.supabase.co`

Flujo:

1. actualizar copia local al último SOURCE verde;
2. ejecutar Desktop contra QA remota;
3. ejecutar Android emulator contra la misma QA;
4. usar ORG_A y ORG_B simultáneamente;
5. si aparece un bug Flutter:
   - corregir SOURCE;
   - añadir/regresar prueba automatizada;
   - sincronizar CI;
   - exigir CI completo verde;
   - actualizar copia local;
   - reintentar el caso manual;
6. si aparece un bug SQL/RLS/RPC:
   - corregir con migración nueva cuando corresponda;
   - SOURCE -> CI verde;
   - aplicar sólo a QA;
   - repetir la prueba;
7. no ejecutar `supabase db reset` remoto como reflejo automático de cada
   cambio de frontend.

Este carril es para iterar rápido.

### Carril B — aceptación formal

Sólo cuando Carril A deje de descubrir fallos bloqueantes.

Reiniciar desde cero:

- L00
- L01
- L02
- L03
- L04
- L05
- L06
- L07
- L08/T19

Sobre el último SHA exacto que haya pasado CI.

No reutilizar evidencia L00/L01 del SHA `05f344...`.

---

## 12. Plan detallado de las siguientes pruebas manuales

### 12.1 Preparación

Antes de abrir apps:

- `git fetch origin feature/saas-multitenant-foundation`
- comprobar HEAD remoto;
- actualizar con `git pull --ff-only`;
- verificar que el working tree esté limpio;
- no hacer `stash pop` de archivos generados antiguos;
- obtener URL y clave publishable/anon de QA mediante un medio seguro;
- no versionar claves;
- no usar `service_role` en Flutter.

### 12.2 Smoke simultáneo Desktop + Android

Desktop:

- iniciar contra QA remota;
- login ORG_A;
- confirmar branding `StOmni QA ORG_A`;
- dashboard visible;
- navegar por todos los destinos del sidebar;
- reducir altura de ventana;
- comprobar que no reaparece:
  `!semantics.parentDataDirty`;
- comprobar que no existe pantalla blanca;
- comprobar scroll del sidebar.

Android emulator:

- iniciar contra QA remota;
- login ORG_B;
- confirmar branding `StOmni QA ORG_B`;
- abrir Almacén;
- comprobar que no reaparece:
  `duplicate column name: unit_configuration`;
- entrar/salir de Registro de producto;
- comprobar navegación básica.

### 12.3 Cambio de tenant/sesión

En el mismo Android:

1. ORG_B logueada;
2. logout;
3. login ORG_A;
4. verificar branding y datos;
5. logout;
6. login ORG_B;
7. verificar que no se filtren:
   - nombre de empresa anterior;
   - dashboard;
   - productos;
   - caches;
   - permisos;
   - sesión anterior.

En Desktop mantener la otra empresa abierta como referencia cuando sea útil.

Objetivo especial:

revalidar el bug histórico de logout donde aparecieron:

- `permission denied for function get_dashboard_summary`
- `Bad state: Cannot use "ref" after the widget was disposed`

La corrección vigente de `dashboard_tab.dart` usa el estado de
`authControllerProvider` y no accede directamente a `supabaseProvider`
desde UI.

### 12.4 Flujo funcional crítico

Con datos sintéticos y separados por tenant:

- crear producto en ORG_A;
- comprobar que no aparece en ORG_B;
- crear producto en ORG_B;
- comprobar que no aparece en ORG_A;
- ingreso de mercadería;
- stock por almacén;
- crear cliente;
- cotización/venta;
- caja;
- pago;
- compras si el plan/capability lo permite;
- validar contrato canónico de `tipo_venta`;
- probar producto con configuración de unidades;
- probar stock mínimo visible vs almacenamiento escalado.

No relajar el backend para “hacer pasar” fixtures incompatibles.

### 12.5 Fiscal / Edge Functions

Antes de considerar esta parte evidencia:

- verificar que Edge Functions QA correspondan al SOURCE vigente;
- verificar secrets/configuración exclusivamente QA;
- no usar credenciales de producción salvo autorización expresa;
- ejecutar casos de emitir/consultar/reintentar/reconciliar sólo en un entorno
  fiscal de prueba cuando aplique;
- confirmar aislamiento de Storage por tenant.

### 12.6 Offline/cache/sesión

Android:

- con sesión activa, cargar datos;
- cortar conectividad;
- navegar por superficies que admitan cache;
- reconectar;
- verificar que no duplique operaciones;
- verificar que no mezcle ORG_A/ORG_B;
- cerrar/reabrir app;
- repetir navegación de Almacén para probar SQLite persistente.

Esto es especialmente importante porque el bug de
`unit_configuration` sólo apareció con un estado local real.

### 12.7 Pruebas adversariales manuales

Cubrir al menos:

- ORG_A intenta leer ID de ORG_B;
- ORG_A intenta mutar ID de ORG_B;
- RPC con IDs de otro tenant;
- Storage path ajeno;
- endpoints Edge con tenant ajeno;
- usuario sin permiso;
- sesión expirada;
- logout durante carga de dashboard;
- doble submit/idempotencia donde aplique.

Los fallos esperados deben ser fail-closed.

### 12.8 Cierre formal

Cuando el carril rápido ya esté estable:

1. congelar el último candidato CI verde;
2. ejecutar L00 desde cero;
3. reconstruir local en L01;
4. ejecutar L02-L07 según plan 100;
5. recopilar evidencia;
6. completar L08/T19;
7. sólo entonces evaluar GO/No-Go.

---

## 13. Qué NO debe hacer la siguiente IA

No:

- tocar `main`;
- hacer merge;
- usar un SHA viejo porque “ya estaba verde”;
- marcar L00/L01 actuales como PASS con evidencia de `05f344...`;
- reintroducir aliases de `tipo_venta`;
- volver a schema v1 de unit profile;
- crear `productos.unit_configuration` en PostgreSQL para arreglar SQLite;
- desactivar tests/gates para obtener verde;
- ignorar el error Semantics porque Windows compile;
- borrar la DB SQLite como única “solución” al bug;
- usar QA remota como si fuera producción;
- poner service_role en `--dart-define`;
- asumir que las 21 Edge Functions remotas están sincronizadas con SOURCE;
- declarar T19/GO sin L00-L08 vigentes.

---

## 14. Cómo actuar ante un nuevo bug

Si el usuario muestra captura/error:

1. clasificar:
   - Flutter/UI;
   - SQLite/cache local;
   - Supabase SQL/RLS/RPC;
   - Edge Function;
   - Storage;
   - integración externa;
2. reproducir o encontrar evidencia mínima;
3. localizar el código;
4. corregir SOURCE;
5. añadir prueba de regresión siempre que sea razonable;
6. revisar format/analyze;
7. sincronizar a CI;
8. esperar CI completo verde;
9. actualizar el cliente local;
10. repetir el caso manual contra QA;
11. documentar resultado;
12. si cambió código, recordar que la aceptación formal deberá empezar de nuevo
    sobre ese nuevo SHA.

---

## 15. Estado de cierre de esta auditoría

Estado al redactar:

- arquitectura SaaS implementada;
- contrato canónico de productos endurecido;
- CI funcional anterior completamente verde;
- pantallazo blanco/Semantics Desktop corregido y cubierto por test;
- SQLite duplicate column mobile corregido y cubierto por test;
- gate SaaS actualizado para exigir la migración SQLite idempotente;
- Supabase QA alineada a las 125 migraciones;
- ORG_A y ORG_B preparadas;
- Edge Functions remotas presentes, pero no redeployadas como parte de esta
  alineación;
- QA manual simultánea Desktop + Android es el siguiente trabajo inmediato;
- aceptación formal L00-L08 debe reiniciarse desde cero sobre el último
  candidato CI verde después de terminar las iteraciones de QA.

---

## 16. Prompt de continuidad recomendado

Usar el prompt entregado al usuario junto con este documento. La siguiente IA
debe empezar leyendo los documentos de la sección 2 y verificando los SHAs
actuales antes de ejecutar cambios.
