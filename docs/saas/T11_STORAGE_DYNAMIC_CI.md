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
| T11-03 | A no enumera ni descarga mediante endpoint *authenticated* el objeto de B |
| T11-04 | A no inserta, reemplaza ni elimina la imagen de B; los bytes de B se mantienen |
| T11-05 | Logos propios permitidos, escritura/reemplazo/borrado ajenos prohibidos |
| T11-06 | Fiscal privado sembrado sólo por service-role no queda descargable ni enumerable desde A o URL pública |
| T11-07 | A no sube PDF en ruta fiscal de B ni emite una URL firmada para el PDF ajeno |
| T11-08 | La URL pública directa de imágenes/logos sigue funcionando por contrato (assets públicos) |

**Distinción de seguridad:** los buckets `logos` e `imagenes_productos` tienen `public=true`. Una URL pública conocida puede servir sus imágenes a cualquier visitante; no se puede prometer confidencialidad de esos bytes. La privacidad estricta aplica a `comprobantes-electronicos`. La protección de *listado mediante API autenticada y escritura* debe mantenerse por empresa. Si un logo público puede enumerarse por listado de otro tenant, registrarlo como exposición de metadata y resolverlo sin romper los enlaces públicos previstos.

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
