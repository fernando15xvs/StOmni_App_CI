import {
  consultarGuiaCore,
  createUserContext,
  emitirGuiaCore,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/guia_remision_common.ts'
import {
  bindObservationJob,
  markObservationOutcome,
  serveObserved,
} from '../_shared/observability.ts'

Deno.serve(serveObserved('reintentar-guias-pendientes', async (req) => {
  const options = handleOptions(req)
  if (options) return options

  try {
    if (req.method !== 'POST') throw new HttpError(405, 'Método no permitido')
    const context = await createUserContext(req, ['admin'])
    const organizationId = context.employee?.organizationId ?? ''
    if (!organizationId) throw new HttpError(403, 'Organización activa requerida')

    const jobId = crypto.randomUUID()
    bindObservationJob(req, jobId)
    const body = await req.json().catch(() => ({}))
    const limite = Math.max(1, Math.min(Number(body?.limite || 1), 10))

    const { data, error } = await context.admin
      .from('guias_remision')
      .select('id, estado, ticket_sunat, ultimo_intento_at')
      .eq('organization_id', organizationId)
      .in('estado', [
        'pendiente_envio',
        'pendiente_reintento',
        'ticket_pendiente',
        'procesando',
      ])
      .order('ultimo_intento_at', { ascending: true, nullsFirst: true })
      .order('created_at', { ascending: true })
      .limit(Math.min(limite * 5, 50))

    if (error) throw new HttpError(500, error.message, error)

    const now = Date.now()
    const cooldownMs = 30 * 60 * 1000
    const candidates = (data || [])
      .filter((item: any) => {
        if (!item.ultimo_intento_at) return true
        const last = Date.parse(String(item.ultimo_intento_at))
        return Number.isNaN(last) || now - last >= cooldownMs
      })
      .slice(0, limite)

    const resultados = []
    let failed = 0
    for (const item of candidates) {
      try {
        const result = item.ticket_sunat
          ? await consultarGuiaCore(context, String(item.id), true)
          : await emitirGuiaCore(context, String(item.id), 'reintentar')
        resultados.push({
          guia_id: item.id,
          success: true,
          estado: result?.estado,
        })
      } catch (error) {
        failed += 1
        resultados.push({
          guia_id: item.id,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        })
      }
    }

    if (candidates.length === 0) {
      markObservationOutcome(req, 'skipped')
    } else if (failed > 0) {
      markObservationOutcome(req, 'failed', 'BATCH_PARTIAL_FAILURE')
    }

    return jsonResponse({
      success: true,
      job_id: jobId,
      procesadas: resultados.length,
      fallidas: failed,
      resultados,
    })
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : String(error),
      details: error instanceof HttpError ? error.details : undefined,
    }, status)
  }
}))
