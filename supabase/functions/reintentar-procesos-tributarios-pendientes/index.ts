import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import {
  createUserContext,
  errorResponse,
  handleOptions,
  jsonResponse,
  retryPending,
} from '../_shared/proceso_tributario_common.ts'
import {
  bindObservationJob,
  markObservationOutcome,
  serveObserved,
} from '../_shared/observability.ts'

serve(serveObserved('reintentar-procesos-tributarios-pendientes', async (req: Request) => {
  const options = handleOptions(req)
  if (options) return options
  if (req.method !== 'POST') return jsonResponse({ error: 'Método no permitido' }, 405)

  try {
    const context = await createUserContext(req, ['admin'])
    const jobId = crypto.randomUUID()
    bindObservationJob(req, jobId)
    const body = await req.json().catch(() => ({}))
    const limite = Math.min(Math.max(Number(body?.limite ?? 20), 1), 100)
    const pendientes = await retryPending(context, limite)

    if (pendientes.length === 0) {
      markObservationOutcome(req, 'skipped')
    }

    return jsonResponse({
      success: true,
      job_id: jobId,
      pendientes_revisados: pendientes,
      procesos_creados: 0,
      mensaje:
        'Se revisaron manualmente procesos existentes. Los resultados inciertos quedaron excluidos.',
    })
  } catch (error) {
    return errorResponse(error)
  }
}))
