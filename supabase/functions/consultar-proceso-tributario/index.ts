import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import {
  consultarProcesoCore,
  createUserContext,
  errorResponse,
  handleOptions,
  jsonResponse,
} from '../_shared/proceso_tributario_common.ts'
import { serveObserved } from '../_shared/observability.ts'

serve(serveObserved('consultar-proceso-tributario', async (req: Request) => {
  const options = handleOptions(req)
  if (options) return options
  if (req.method !== 'POST') return jsonResponse({ error: 'Método no permitido' }, 405)

  try {
    const context = await createUserContext(req, ['admin'])
    const organizationId = context.employee?.organizationId ?? ''
    if (!organizationId) return jsonResponse({ error: 'Organización activa requerida' }, 403)

    const body = await req.json()
    const procesoId = String(body?.proceso_id ?? '').trim()
    if (!procesoId) return jsonResponse({ error: 'proceso_id es obligatorio' }, 400)

    const { data: owned, error: ownershipError } = await context.admin
      .from('procesos_tributarios')
      .select('id')
      .eq('organization_id', organizationId)
      .eq('id', procesoId)
      .maybeSingle()
    if (ownershipError) throw ownershipError
    if (!owned) return jsonResponse({ error: 'Proceso no encontrado' }, 404)

    return jsonResponse(await consultarProcesoCore({
      context,
      procesoId,
      consultarSunat: body?.consultar_sunat === true,
    }))
  } catch (error) {
    return errorResponse(error)
  }
}))