import {
  createUserContext,
  emitirGuiaCore,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/guia_remision_common.ts'
import {
  assertTenantResource,
  AuthGuardError,
} from '../_shared/auth_guard.ts'
import { serveObserved } from '../_shared/observability.ts'

Deno.serve(serveObserved('reintentar-guia-remision', async (req) => {
  const options = handleOptions(req)
  if (options) return options

  try {
    const body = await req.json()
    const guiaId = String(body?.guia_id || '').trim()
    if (!guiaId) throw new HttpError(400, 'guia_id es obligatorio')
    const forzar = body?.forzar === true
    const context = await createUserContext(req, forzar ? ['admin'] : ['admin', 'operador'])

    await assertTenantResource(
      context.admin,
      context.employee?.organizationId ?? '',
      'guias_remision',
      'id',
      guiaId,
      'Guía de remisión',
    )

    return jsonResponse(await emitirGuiaCore(
      context,
      guiaId,
      'reintentar',
      forzar,
    ))
  } catch (error) {
    const status = error instanceof HttpError || error instanceof AuthGuardError
      ? error.status
      : 500
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : String(error),
      details: error instanceof HttpError ? error.details : undefined,
    }, status)
  }
}))
