import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import {
  createUserContext,
  errorResponse,
  handleOptions,
  jsonResponse,
  prepararProcesos,
  processPreparedIds,
} from '../_shared/proceso_tributario_common.ts'
import {
  bindObservationJob,
  serveObserved,
} from '../_shared/observability.ts'

serve(serveObserved('ejecutar-resumen-diario', async (req: Request) => {
  const options = handleOptions(req)
  if (options) return options
  if (req.method !== 'POST') return jsonResponse({ error: 'Método no permitido' }, 405)

  try {
    const context = await createUserContext(req, ['admin'])
    const jobId = crypto.randomUUID()
    bindObservationJob(req, jobId)
    const body = await req.json().catch(() => ({}))
    const limite = Math.min(Math.max(Number(body?.limite ?? 500), 1), 500)

    // Primera salida: ejecución exclusivamente manual por administrador.
    // Agrupa solicitudes pendientes que deben comunicarse mediante RC.
    const ids = await prepararProcesos(context, 'resumen_boletas', limite)
    const procesos = await processPreparedIds(context, ids)

    return jsonResponse({
      success: true,
      job_id: jobId,
      procesos_creados: ids.length,
      procesos,
      sin_documentos: ids.length === 0,
      mensaje: ids.length === 0
        ? 'No hay solicitudes de boletas pendientes para agrupar.'
        : 'Los resúmenes fueron creados y procesados manualmente.',
    })
  } catch (error) {
    return errorResponse(error)
  }
}))
