# Refactor reutilizable — registro histórico

Este archivo quedó **supersedido** al cerrar y validar `feature/desktop-architecture-refactor` el 6 de septiembre de 2026.

La fuente canónica para conocer el estado final, decisiones vigentes, módulos implementados, evidencia de validación y pasos de promoción es:

- `docs/AUDITORIA_CONTINUIDAD_DESKTOP_REFACTOR.md`
- `docs/PLAN_LOCAL_MULTIPLATAFORMA.md`

Los estados parciales que antiguamente figuraban aquí ya no deben usarse para decidir qué implementar a continuación.

## Estado final de traspaso

- Fases 0–9: ✅ implementadas y validadas localmente.
- `core_logic`: ✅ analyze + tests.
- `mobile_app`: ✅ analyze + 227 tests.
- `desktop_app`: ✅ analyze + 2 tests + build Windows debug.
- SQL pendiente: ✅ validado en laboratorio temporal mediante snapshot remoto de solo lectura + migraciones pendientes + pgTAP + lint.
- Gate integral `scripts/verify_refactor_local.ps1 -DesktopTarget windows`: ✅ completo, sin omisiones.
- Compras, variantes, pricing/promociones, trazabilidad, servicios no inventariables y métricas configurables: ✅ cerrados dentro del alcance del roadmap.
- No hay merge a `main`.
- No se aplicaron migraciones nuevas a Supabase remoto durante la validación.
- GitHub Pages no se actualizó como parte del cierre.

El siguiente trabajo ya no es implementar fases nuevas: corresponde a **promoción/release controlado** (migraciones remotas cuando se autoricen, smoke funcional, merge a `main` y despliegue).