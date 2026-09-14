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

serve(serveObserved('procesar-bajas-tributarias', async (req: Request) => {
  const options = handleOptions(req)
  if (options) return options
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Método no permitido' }, 405)
  }

  try {
    const context = await createUserContext(req, ['admin'])
    const jobId = crypto.randomUUID()
    bindObservationJob(req, jobId)
    const body = await req.json().catch(() => ({}))
    const limite = Math.min(
      Math.max(Number(body?.limite ?? 500), 1),
      500,
    )
    const tipo = String(body?.tipo_proceso ?? '').trim() || null

    // Esta acción crea únicamente procesos nuevos para solicitudes pendientes.
    // Los procesos que ya tienen ticket se consultan desde su pantalla de detalle.
    const ids = await prepararProcesos(context, tipo, limite)
    const nuevos = await processPreparedIds(context, ids)

    return jsonResponse({
      success: true,
      job_id: jobId,
      tipo_proceso: tipo ?? 'todos',
      procesos_creados: ids.length,
      procesos: nuevos,
      pendientes_revisados: [],
      sin_documentos: ids.length === 0,
    })
  } catch (error) {
    return errorResponse(error)
  }
}))
