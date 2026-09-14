import {
  consultarComprobanteCore,
  createUserContext,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/facturacion_common.ts'
import {
  assertTenantResource,
  AuthGuardError,
} from '../_shared/auth_guard.ts'
import { serveObserved } from '../_shared/observability.ts'

Deno.serve(serveObserved('consultar-comprobante', async (req: Request) => {
  const preflight = handleOptions(req)
  if (preflight) return preflight

  try {
    if (req.method !== 'POST') throw new HttpError(405, 'Método no permitido')
    const context = await createUserContext(req)
    const body = await req.json().catch(() => ({}))
    const comprobanteId = String(body?.comprobante_id || '').trim()
    if (!comprobanteId) throw new HttpError(400, 'comprobante_id es obligatorio')

    await assertTenantResource(
      context.admin,
      context.employee?.organizationId ?? '',
      'comprobantes_electronicos',
      'id',
      comprobanteId,
      'Comprobante',
    )

    const result = await consultarComprobanteCore({
      comprobanteId,
      consultarSunat: body?.consultar_sunat === true,
      context,
    })
    return jsonResponse(result)
  } catch (error) {
    const status = error instanceof HttpError || error instanceof AuthGuardError
      ? error.status
      : 500
    const message = error instanceof Error ? error.message : String(error)
    return jsonResponse({ success: false, error: message }, status)
  }
}))