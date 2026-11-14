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
