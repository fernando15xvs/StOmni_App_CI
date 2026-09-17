# StOmni Mobile

`packages/mobile_app` es el cliente móvil de StOmni.

## Plataformas soportadas

- Android
- iOS

Web **no** forma parte de este paquete. No se debe agregar ni regenerar `packages/mobile_app/web/` para publicar StOmni en navegador.

La futura experiencia Web se implementará como un cliente independiente, previsto como `packages/web_app`, reutilizando `packages/core_logic` donde la lógica sea agnóstica de plataforma y definiendo una presentación e infraestructura de cache/persistencia propias del navegador.

La decisión y su evidencia están documentadas en:

`docs/saas/101_AUDITORIA_FRONTERA_PLATAFORMAS_Y_WEB_FUTURA.md`
