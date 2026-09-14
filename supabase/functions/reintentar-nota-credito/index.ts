import {
  createUserContext,
  emitirNotaCreditoCore,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/nota_credito_common.ts'
import {
  assertTenantResource,
  AuthGuardError,
} from '../_shared/auth_guard.ts'
import { serveObserved } from '../_shared/observability.ts'

Deno.serve(serveObserved('reintentar-nota-credito', async (req) => {
  const options = handleOptions(req)
  if (options) return options

  try {
    if (req.method !== 'POST') {
      throw new HttpError(405, 'Método no permitido')
    }

    const body = await req.json()
    const notaCreditoId = String(body?.nota_credito_id || '').trim()
    if (!notaCreditoId) {
      throw new HttpError(400, 'nota_credito_id es obligatorio')
    }

    const forzar = body?.forzar === true
    const context = await createUserContext(req, forzar ? ['admin'] : ['admin', 'operador'])
    await assertTenantResource(
      context.admin,
      context.employee?.organizationId ?? '',
      'notas_credito',
      'id',
      notaCreditoId,
      'Nota de crédito',
    )

    const result = await emitirNotaCreditoCore({
      notaCreditoId,
      accion: 'reintentar',
      forzar,
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
