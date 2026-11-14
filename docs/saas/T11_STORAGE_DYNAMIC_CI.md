# T11 — Evidencia dinámica Storage en laboratorio local

## Alcance y estado

**Implementación del probe: versionada. Gate T11 completo: pendiente.**

El flujo `scripts/run_saas_e2e_ci.mjs` ejecuta el E2E de dos empresas con JWT reales de `authenticated` y, sin guardar credenciales ni tokens, llama a `verifyTenantStorage` en `supabase/tests/e2e/tenant_storage_e2e.mjs`.

El script exige la API de Supabase local en HTTP loopback. No actúa contra Supabase remoto; los datos son sintéticos y se restauran/reinicializan con T03/T18. El reporte de CI conserva únicamente IDs de escenarios, IDs de empresas y resultados sanitizados.

## Matriz automatizada de ataque

| Escenario | Resultado requerido |
|---|---|
| T11-01 | ORG_A y ORG_B suben PNG con JWT propios bajo `<organization_id>/products/` |
| T11-02 | Ambas ven sus imágenes en LIST y A puede usar la ruta autenticada de lectura propia |
| T11-03 | A no enumera el objeto B; la lectura de bytes públicos por ruta conocida se trata como pública, incluso si el endpoint es *authenticated* |
| T11-04 | A no inserta, reemplaza ni elimina la imagen de B; los bytes de B se mantienen |
| T11-05 | Logos propios permitidos, escritura/reemplazo/borrado ajenos prohibidos |
| T11-06 | Fiscal privado sembrado sólo por service-role no queda descargable ni enumerable desde A o URL pública |
| T11-07 | A no sube PDF en ruta fiscal de B ni emite una URL firmada para el PDF ajeno |
| T11-08 | La URL pública directa de imágenes/logos sigue funcionando por contrato (assets públicos) |

**Distinción de seguridad:** los buckets `logos` e `imagenes_productos` tienen `public=true`. Una URL pública conocida puede servir sus imágenes a cualquier visitante; no se puede prometer confidencialidad de esos bytes. La privacidad estricta aplica a `comprobantes-electronicos`. En Supabase, incluso `/object/authenticated` puede servir contenido de un bucket público: no utilizar ese endpoint como prueba de confidencialidad. La separación por tenant debe impedir la enumeración de metadatos y toda mutación ajena. La protección de *listado mediante API autenticada y escritura* debe mantenerse por empresa. Si un logo público puede enumerarse por listado de otro tenant, registrarlo como exposición de metadata y resolverlo sin romper los enlaces públicos previstos.

## Reglas de cierre

1. No marcar T11 verde sólo porque la suite automatizada pasa; faltan pruebas exhaustivas de RLS para cada bucket, expiración real de URL firmada y revisión de rutas fiscales completas.
2. Toda falla de aislamiento en las mutaciones, objeto fiscal privado o URL firmada debe bloquear CI y la decisión de release.
3. Si la API devuelve éxito a una eliminación fuera de alcance con 0 filas afectadas, comprobar los bytes del objeto B: no confundir éxito HTTP con autorización de borrar.
4. No introducir service-role en clientes Flutter. Este probe lo usa únicamente en el runner local para crear el PDF fiscal de prueba.
5. Los siguientes pasos pertenecen a T10 (Edge JWT y tenant server-side), T11 (URLs firmadas/metadata) y T19 (evidencia agregada/GO-NO-GO).

## Evidencia

- CI: `StOmni SaaS Full Validation`, job `Automated backend validation`, paso `T05-T09/T12/T14 representative multi-tenant E2E`.
- Reporte: `.dart_tool/saas/f9_1_e2e_report.json` (contiene 18 escenarios, de ellos 8 T11, sólo si el probe pasa).
- Fuente: `supabase/tests/e2e/tenant_storage_e2e.mjs`.
- Estado inicial: esperar ejecución sobre candidato actualizado. No atribuir éxito antes de que CI termine.

## Resultado de la primera ejecución adversarial y corrección

- **CI #43629431016 (candidato previo): FAIL** en `T11-03`: ORG_A pudo enumerar una imagen ORG_B con `object/list/imagenes_productos`.
- Causa identificada en `20260908059500_saas_runtime_surface_reconciliation.sql`: la migración restablecía `productos_imagenes_public_select` y `logos_public_select` como SELECT para `public`, lo que habilitaba listar metadatos.
- Corrección aditiva: `supabase/migrations/20261114195500_t11_storage_tenant_select_no_public_listing.sql` elimina esos dos SELECT globales y restablece SELECT autenticado `tenant.read` por `organization_id` y segmento de carpeta.
- Contrato actualizado: `supabase/tests/database/storage_surface_contract_test.sql` (11 aserciones). Los buckets siguen siendo públicos **sólo para lectura directa de URL**; documentos fiscales siguen privados.
- **Pendiente:** verificar la corrección en una ejecución completa CI; el hallazgo no se declara resuelto hasta confirmar T11 verde y no-drifts tras reset.

- **CI #43630538800 (candidato con migración):** pasó la condición de listado cruzado, pero T11-03 falló por asumir erróneamente que GET autenticado de un bucket público debía denegarse. Se corrigió el probe para exigir aislamiento en LIST y conservar el contrato de bytes públicos; las pruebas de artefactos privados siguen estrictas. Revalidación completa pendiente.

## Extensión T11: caducidad real de URL firmada fiscal

Se añade el caso `T11-09-private-signed-url-expiry-enforced`: el runner local crea una firma temporal de dos segundos con la llave administrativa **solo del laboratorio**, comprueba que descarga el PDF sintético correcto y confirma el rechazo al repetir la descarga después de 5,5 segundos. La firma y su token nunca se imprimen ni se incluyen en los artefactos.

Este ensayo distingue el control de *autorización para emitir firmas* del control de *caducidad de una firma previamente autorizada*. No implica que ORG_A/B puedan emitir firmas sin Edge o RLS adecuados.

**Estado:** CI #43632545921 validó T11-01–T11-08 junto con restauración T18. El nuevo caso T11-09 está implementado, pero aún debe superar una ejecución CI. El resto de rutas fiscales y operaciones Edge privilegiadas siguen sujetos a T10/T16 y al cierre T19.
