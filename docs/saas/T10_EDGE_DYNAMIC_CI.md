# T10 — Prueba dinámica de frontera JWT Edge (laboratorio)

## Estado

**Probe dinámico de autenticación implementado; pendiente ejecución CI y cobertura adversarial con JWT válido.** No equivale a cerrar T10 entero ni a autorizar producción.

`supabase/tests/e2e/edge_jwt_boundary_e2e.mjs` lee el inventario de `supabase/config.toml`, comprueba `verify_jwt=true` para las 21 Edge Functions y realiza 42 solicitudes HTTP reales contra el Supabase *local*:

1. Una solicitud sin cabecera Authorization a cada función.
2. Otra con JWT intencionalmente malformado más `x-stomni-organization-id` y `organization_id` falsificados.

Se exige rechazo HTTP 401/403 en ambos intentos. No se invoca ninguna operación fiscal real ni API externa con JWT válido. El runner impone API HTTP loopback y guarda un reporte sanitizado, sin secretos.

El workflow `StOmni SaaS Full Validation` ejecuta esta prueba después de levantar Supabase local y del E2E de dos empresas. El resultado se guarda en `.dart_tool/saas/t10_edge_jwt_boundary_report.json`.

## Límites y siguientes pruebas

- Estos 42 rechazos sólo verifican **frontera JWT**, no el aislamiento integral de los 21 handlers con sesiones válidas.
- Pendiente: 2 JWT válidos de ORG_A/B con empleado y permisos reales, referencias cruzadas para cada ruta fiscal, GRE y funciones administrativas, con respuestas sanitizadas y datos sintéticos.
- Pendiente: verificar que ningún proceso `service_role` ignora el tenant, incluyendo jobs y callbacks internos autorizados.
- Los tests dinámicos deben fallar si una función deja de rechazar peticiones anónimas. No deben declarar GO final ni probar sobre un Supabase remoto.

## Hallazgo dinámico y corrección

- **CI #43631002518:** T11 superó sus ocho ataques, pero el paso T10 detectó HTTP 400 en `reintentar-comprobante` sin JWT. La validación de `comprobante_id` ocurría antes de `createUserContext(req)`.
- Revisión de 21 Edge Functions: cinco rutas fiscales admitían validación o parsing de payload antes de resolver la identidad. Corregidas: `reintentar-comprobante`, `emitir-nota-credito`, `reintentar-nota-credito`, `consultar-nota-credito` y `reintentar-guia-remision`.
- En reintentos con `forzar=true`, la autorización de `admin` se conserva mediante un chequeo explícito después de autenticar con el rol base permitido. Los operadores no pueden forzar el reintento.
- El gate `scripts/verify_saas_edge_functions.mjs` impide ahora introducir `await req.json()` antes de la primera resolución de sesión/rol y contiene un self-test del orden de autorización.
- **Pendiente:** nueva ejecución CI y escenarios con JWT válidos para certificar autorización por recurso/tenant.

## Nueva validación con JWT de sesión real (candidato siguiente)

El E2E de dos organizaciones incorpora ahora `edge_tenant_employee_e2e.mjs` con **8 escenarios T10-V01–T10-V08**. Cada organización posee su propio usuario Auth y empleado administrador creado por el bootstrap SaaS.

Se verifican ambos sentidos A→B y B→A con JWT válido, el header `x-stomni-organization-id` falsificado y la PK **real** del empleado ajeno. Los endpoints `delete_employee` y `create_employee` deben devolver 404 al acceder a empleados de otra organización. Se comprueba después, mediante una sesión local privilegiada usada solo por el runner, que ambas fichas y membresías permanecen activas e idénticas. `get-persona` comprueba que el guard de sesión acepta al propietario legítimo antes de validar un body vacío, sin realizar consultas DNI/RUC externas.

Las pruebas son sólo contra loopback, utilizan datos sintéticos, no publican JWT, emails, contraseñas ni identificadores individuales en la evidencia y bloquean CI si hay acceso cruzado.

**Estado:** implementadas en GitHub, ejecución CI pendiente. Esto amplía T10, pero **no** certifica aún toda la superficie fiscal con JWT válidos, procesos internos ni los 21 handlers de forma individual. CI #43632545921 validó los 42 rechazos JWT previos y terminó verde.
