import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import {
  assertTenantResource,
  AuthGuardError,
  requireEmployee,
} from '../_shared/auth_guard.ts'
import { serveObserved } from '../_shared/observability.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    },
  })
}

const fiscalTableByType: Record<string, string> = {
  comprobante: 'comprobantes_electronicos',
  nota_credito: 'notas_credito',
  guia: 'guias_remision',
  proceso: 'procesos_tributarios',
}

serve(serveObserved('resolver-resultado-incierto', async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return response({ success: false, error: 'Método no permitido' }, 405)

  try {
    const context = await requireEmployee(req, ['admin'])
    const body = await req.json().catch(() => ({}))
    const tipoDocumento = String(body?.tipo_documento || '').trim().toLowerCase()
    const documentoId = String(body?.documento_id || '').trim()
    const decision = String(body?.decision || '').trim().toLowerCase()
    const motivo = String(body?.motivo || '').trim()
    const referenciaExterna = String(body?.referencia_externa || '').trim()

    const table = fiscalTableByType[tipoDocumento]
    if (!table) {
      return response({ success: false, error: 'tipo_documento inválido' }, 400)
    }
    if (!documentoId) return response({ success: false, error: 'documento_id es obligatorio' }, 400)
    if (!['habilitar_reintento', 'mantener_incierto'].includes(decision)) {
      return response({ success: false, error: 'decision inválida' }, 400)
    }
    if (motivo.length < 10 || motivo.length > 500) {
      return response({
        success: false,
        error: 'El motivo debe tener entre 10 y 500 caracteres e indicar cómo se verificó el estado remoto.',
      }, 400)
    }

    // Defensa en profundidad: el UUID procedente del cliente debe existir dentro
    // del tenant antes de llegar al RPC service_role. PostgreSQL vuelve a validar
    // el mismo tenant mediante x-stomni-organization-id.
    await assertTenantResource(
      context.admin,
      context.organizationId,
      table,
      'id',
      documentoId,
      'Documento fiscal',
    )

    const { data, error } = await context.admin.rpc(
      'resolver_resultado_incierto_v1',
      {
        p_tipo_documento: tipoDocumento,
        p_documento_id: documentoId,
        p_decision: decision,
        p_motivo: motivo,
        p_referencia_externa: referenciaExterna || null,
        p_usuario_id: context.user.id,
      },
    )

    if (error) return response({ success: false, error: error.message }, 409)
    return response(data)
  } catch (error) {
    const status = error instanceof AuthGuardError ? error.status : 500
    return response({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    }, status)
  }
}))
