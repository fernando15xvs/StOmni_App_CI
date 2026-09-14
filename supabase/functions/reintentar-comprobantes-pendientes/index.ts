import {
  createUserContext,
  emitirComprobanteCore,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/facturacion_common.ts'
import {
  bindObservationJob,
  markObservationOutcome,
  serveObserved,
} from '../_shared/observability.ts'

Deno.serve(serveObserved('reintentar-comprobantes-pendientes', async (req: Request) => {
  const preflight = handleOptions(req)
  if (preflight) return preflight

  try {
    if (req.method !== 'POST') throw new HttpError(405, 'Método no permitido')
    const context = await createUserContext(req, ['admin'])
    const organizationId = context.employee?.organizationId ?? ''
    if (!organizationId) throw new HttpError(403, 'Organización activa requerida')

    const jobId = crypto.randomUUID()
    bindObservationJob(req, jobId)
    const body = await req.json().catch(() => ({}))
    const limit = Math.max(1, Math.min(Number(body?.limite || 10), 50))

    const { data, error } = await context.admin
      .from('comprobantes_electronicos')
      .select('id, estado, numero_reintentos, ultimo_intento_at, created_at')
      .eq('organization_id', organizationId)
      .in('estado', ['pendiente', 'pendiente_envio', 'pendiente_reintento', 'procesando'])
      .order('ultimo_intento_at', { ascending: true, nullsFirst: true })
      .order('created_at', { ascending: true })
      .limit(Math.min(limit * 5, 250))

    if (error) throw new HttpError(500, error.message)

    const now = Date.now()
    const cooldownMs = 30 * 60 * 1000
    const candidates = (data || [])
      .filter((item: any) => {
        if (Number(item.numero_reintentos || 0) >= 30) return false
        if (!item.ultimo_intento_at) return true
        const last = Date.parse(String(item.ultimo_intento_at))
        return Number.isNaN(last) || now - last >= cooldownMs
      })
      .slice(0, limit)

    const results: unknown[] = []
    let failed = 0
    for (const item of candidates) {
      try {
        results.push(await emitirComprobanteCore({
          comprobanteId: String(item.id),
          accion: 'reintentar',
          context,
        }))
      } catch (error) {
        failed += 1
        results.push({
          success: false,
          comprobante_id: item.id,
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
      procesados: results.length,
      fallidos: failed,
      resultados: results,
    })
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500
    const message = error instanceof Error ? error.message : String(error)
    return jsonResponse({ success: false, error: message }, status)
  }
}))
