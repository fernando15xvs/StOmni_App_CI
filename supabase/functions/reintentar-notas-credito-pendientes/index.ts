import {
  createUserContext,
  emitirNotaCreditoCore,
  handleOptions,
  HttpError,
  jsonResponse,
} from '../_shared/nota_credito_common.ts'
import {
  bindObservationJob,
  markObservationOutcome,
  serveObserved,
} from '../_shared/observability.ts'

Deno.serve(serveObserved('reintentar-notas-credito-pendientes', async (req) => {
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
    const limite = Math.min(Math.max(Number(body?.limite || 10), 1), 50)

    const { data, error } = await context.admin
      .from('notas_credito')
      .select('id, estado, numero_reintentos, ultimo_intento_at')
      .eq('organization_id', organizationId)
      .in('estado', ['pendiente_envio', 'pendiente_reintento', 'procesando'])
      .order('ultimo_intento_at', { ascending: true, nullsFirst: true })
      .order('created_at', { ascending: true })
      .limit(Math.min(limite * 5, 250))

    if (error) throw new HttpError(500, error.message)

    const now = Date.now()
    const cooldownMs = 30 * 60 * 1000
    const candidates = (data || [])
      .filter((row: any) => {
        if (Number(row.numero_reintentos || 0) >= 30) return false
        if (!row.ultimo_intento_at) return true
        const last = Date.parse(String(row.ultimo_intento_at))
        return Number.isNaN(last) || now - last >= cooldownMs
      })
      .slice(0, limite)

    const resultados: unknown[] = []
    let failed = 0
    for (const row of candidates) {
      try {
        resultados.push(await emitirNotaCreditoCore({
          notaCreditoId: String(row.id),
          accion: 'reintentar',
          context,
        }))
      } catch (error) {
        failed += 1
        resultados.push({
          nota_credito_id: row.id,
          success: false,
          error: error instanceof Error ? error.message : String(error),
        })
      }
    }

    // Recupera exclusivamente stock de notas aceptadas del mismo tenant.
    const { data: stockPendiente, error: stockError } = await context.admin
      .from('notas_credito')
      .select('id')
      .eq('organization_id', organizationId)
      .eq('estado', 'aceptado')
      .eq('reponer_stock', true)
      .eq('stock_aplicado', false)
      .order('created_at', { ascending: true })
      .limit(limite)

    if (stockError) throw new HttpError(500, stockError.message)

    const resultadosStock: unknown[] = []
    let stockFailed = 0
    for (const row of stockPendiente || []) {
      const { data: stockResult, error: aplicarError } = await context.admin.rpc(
        '_aplicar_stock_nota_credito',
        { p_nota_credito_id: String(row.id) },
      )
      const success = !aplicarError && stockResult?.success === true
      if (!success) stockFailed += 1
      resultadosStock.push({
        nota_credito_id: row.id,
        success,
        resultado: stockResult,
        error: aplicarError?.message,
      })
    }

    const totalFailed = failed + stockFailed
    if (candidates.length === 0 && (stockPendiente || []).length === 0) {
      markObservationOutcome(req, 'skipped')
    } else if (totalFailed > 0) {
      markObservationOutcome(req, 'failed', 'BATCH_PARTIAL_FAILURE')
    }

    return jsonResponse({
      success: true,
      job_id: jobId,
      procesados: resultados.length,
      fallidos: failed,
      stock_procesados: resultadosStock.length,
      stock_fallidos: stockFailed,
      resultados,
      resultados_stock: resultadosStock,
    })
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500
    const message = error instanceof Error ? error.message : String(error)
    return jsonResponse({ success: false, error: message }, status)
  }
}))
