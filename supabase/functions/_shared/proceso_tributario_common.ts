import {
  SupabaseClient,
  User,
} from 'https://esm.sh/@supabase/supabase-js@2.49.4'
import {
  AppRole,
  AuthGuardError,
  EmployeeIdentity,
  requireEmployee
} from './auth_guard.ts'

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const BUCKET = 'comprobantes-electronicos'
const DEFAULT_TIMEOUT_MS = 45_000
const STATUS_TIMEOUT_MS = 75_000

export class HttpError extends Error {
  status: number
  details?: unknown

  constructor(status: number, message: string, details?: unknown) {
    super(message)
    this.name = 'HttpError'
    this.status = status
    this.details = details
  }
}

export type TributarioContext = {
  admin: SupabaseClient
  user: User | null
  system: boolean
  employee: EmployeeIdentity | null
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    },
  })
}

export function handleOptions(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  return null
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new HttpError(500, `Falta el secreto ${name}`)
  return value
}

function apiBaseUrl(): string {
  const raw = (
    Deno.env.get('APIS_PERU_BASE_URL') ||
    Deno.env.get('APIS_PERU_RUTA') ||
    'https://facturacion.apisperu.com'
  ).replace(/\/+$/, '')

  return raw.endsWith('/api/v1') ? raw : `${raw}/api/v1`
}

export async function createUserContext(
  req: Request,
  allowedRoles: readonly AppRole[] = ['admin'],
): Promise<TributarioContext> {
  try {
    const context = await requireEmployee(req, allowedRoles)
    return {
      admin: context.admin,
      user: context.user,
      employee: context.employee,
      system: false,
    }
  } catch (error) {
    if (error instanceof AuthGuardError) {
      throw new HttpError(error.status, error.message, error.details)
    }
    throw error
  }
}

function cleanText(value: unknown, fallback = ''): string {
  const text = String(value ?? '').trim()
  return text || fallback
}

function asNumber(value: unknown, fallback = 0): number {
  const number = Number(value)
  return Number.isFinite(number) ? number : fallback
}

function round(value: number, decimals = 2): number {
  const factor = 10 ** decimals
  return Math.round((value + Number.EPSILON) * factor) / factor
}

function formatLimaDateTime(value?: unknown): string {
  const text = cleanText(value)

  // Una columna DATE de PostgreSQL ya representa la fecha tributaria exacta.
  // No debe convertirse como UTC porque retrocedería al día anterior en Lima.
  const dateOnly = text.match(/^(\d{4}-\d{2}-\d{2})(?:T00:00:00(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)?$/)
  if (dateOnly) {
    return `${dateOnly[1]}T00:00:00-05:00`
  }

  const source = value ? new Date(String(value)) : new Date()
  if (Number.isNaN(source.getTime())) {
    throw new HttpError(409, `Fecha tributaria inválida: ${text || 'vacía'}`)
  }

  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Lima',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(source)

  const part = (type: string): string =>
    parts.find((item) => item.type === type)?.value ?? ''

  return `${part('year')}-${part('month')}-${part('day')}T00:00:00-05:00`
}

function responseMessage(body: any, fallback: string): string {
  return cleanText(
    body?.cdrResponse?.description ||
    body?.sunatResponse?.cdrResponse?.description ||
    body?.sunatResponse?.error?.message ||
    body?.error?.message ||
    body?.message ||
    body?.mensaje,
    fallback,
  )
}

function responseCode(body: any): string {
  return cleanText(
    body?.cdrResponse?.code ||
    body?.sunatResponse?.cdrResponse?.code ||
    body?.sunatResponse?.error?.code ||
    body?.error?.code ||
    body?.code,
  )
}

function responseNotes(body: any): unknown[] {
  const notes =
    body?.cdrResponse?.notes || body?.sunatResponse?.cdrResponse?.notes
  return Array.isArray(notes) ? notes : []
}

function responseTicket(body: any): string {
  return cleanText(
    body?.ticket ||
    body?.sunatResponse?.ticket ||
    body?.data?.ticket ||
    body?.response?.ticket,
  )
}

function isAccepted(body: any): boolean {
  const cdr = body?.cdrResponse || body?.sunatResponse?.cdrResponse
  const success = body?.success === true || body?.sunatResponse?.success === true
  const code = cleanText(cdr?.code || body?.code)
  if (cdr?.accepted === true) return true
  if (cdr?.accepted === false) return false
  return success && code === '0'
}

function isTemporaryHttp(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500
}

function isProviderTechnicalError(body: any): boolean {
  const message = responseMessage(body, '').toLowerCase()

  return (
    !body?.cdrResponse &&
    !body?.sunatResponse?.cdrResponse &&
    (
      message.includes('failed to process response headers') ||
      message.includes('error al comunicarse') ||
      message.includes('servidor interno') ||
      message.includes('internal server') ||
      message.includes('connection') ||
      message.includes('timeout') ||
      message.includes('temporarily unavailable')
    )
  )
}

function isTicketStillProcessing(body: any): boolean {
  const code = responseCode(body)
  const message = responseMessage(body, '').toLowerCase()
  return (
    !body?.cdrResponse &&
    !body?.sunatResponse?.cdrResponse &&
    (
      code === '' ||
      code === '98' ||
      code === '99' ||
      message.includes('proceso') ||
      message.includes('ticket') ||
      message.includes('espera') ||
      message.includes('pendiente')
    )
  )
}

function base64ToBytes(raw: string): Uint8Array {
  const normalized = raw.replace(/^data:[^;]+;base64,/, '').trim()
  const binary = atob(normalized)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

function textOrBase64Bytes(raw: string): Uint8Array {
  const text = raw.trim()
  if (text.startsWith('<') || text.startsWith('<?xml')) {
    return new TextEncoder().encode(text)
  }
  return base64ToBytes(text)
}

function isZip(bytes: Uint8Array): boolean {
  return bytes.length > 1 && bytes[0] === 0x50 && bytes[1] === 0x4b
}

async function uploadBytes(
  admin: SupabaseClient,
  path: string,
  bytes: Uint8Array,
  contentType: string,
): Promise<string> {
  const { error } = await admin.storage.from(BUCKET).upload(path, bytes, {
    contentType,
    upsert: true,
    cacheControl: '3600',
  })
  if (error) throw new Error(`No se pudo guardar ${path}: ${error.message}`)
  return path
}

async function apiFetch(
  path: string,
  init: RequestInit,
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<Response> {
  const token = requiredEnv('APIS_PERU_TOKEN')
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(`${apiBaseUrl()}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
        ...(init.headers || {}),
      },
    })
  } finally {
    clearTimeout(timeout)
  }
}

async function responseBody(response: Response): Promise<any> {
  const text = await response.text()
  if (!text) return {}
  try {
    return JSON.parse(text)
  } catch (_) {
    return { raw: text }
  }
}

async function company(admin: SupabaseClient): Promise<any> {
  const { data, error } = await admin
    .from('configuracion_negocio')
    .select('*')
    .eq('id', 1)
    .single()
  if (error || !data) throw new HttpError(409, 'Configuración de empresa no encontrada')
  if (!/^\d{11}$/.test(cleanText(data.ruc))) {
    throw new HttpError(409, 'La empresa no tiene un RUC válido')
  }
  return data
}

async function fetchProceso(
  admin: SupabaseClient,
  procesoId: string,
): Promise<any> {
  const { data, error } = await admin
    .from('procesos_tributarios')
    .select(`
      *,
      procesos_tributarios_detalles(*)
    `)
    .eq('id', procesoId)
    .single()
  if (error || !data) {
    throw new HttpError(404, 'Proceso tributario no encontrado', error?.message)
  }
  return data
}

function companyPayload(config: any): any {
  return {
    ruc: cleanText(config.ruc),
    razonSocial: cleanText(config.razon_social),
    nombreComercial: cleanText(config.nombre_comercial, config.razon_social),
    address: {
      direccion: cleanText(config.direccion),
      provincia: cleanText(config.provincia),
      departamento: cleanText(config.departamento),
      distrito: cleanText(config.distrito),
      ubigueo: cleanText(config.ubigeo),
      codLocal: cleanText(config.cod_local, '0000'),
    },
  }
}

function buildPayload(proceso: any, config: any): any {
  const details = Array.isArray(proceso.procesos_tributarios_detalles)
    ? proceso.procesos_tributarios_detalles
    : []
  if (details.length === 0) throw new HttpError(409, 'El proceso no tiene documentos')

  const common = {
    correlativo: String(proceso.correlativo).padStart(3, '0'),
    fecGeneracion: formatLimaDateTime(proceso.fecha_comunicacion),
    company: companyPayload(config),
    name: `${cleanText(config.ruc)}-${cleanText(proceso.identificador)}`,
  }

  if (proceso.tipo_proceso === 'resumen_boletas') {
    return {
      ...common,
      fecResumen: formatLimaDateTime(proceso.fecha_referencia),
      moneda: 'PEN',
      details: details.map((detail: any) => ({
        tipoDoc: cleanText(detail.tipo_doc),
        serieNro: cleanText(detail.serie_numero),
        estado: '3',
        clienteTipo: cleanText(detail.cliente_tipo, '0'),
        clienteNro: cleanText(detail.cliente_numero, '0'),
        total: round(asNumber(detail.total), 2),
        mtoOperGravadas: round(asNumber(detail.base_imponible), 2),
        mtoOperExoneradas: 0,
        mtoOperInafectas: 0,
        mtoIGV: round(asNumber(detail.igv), 2),
        mtoOtrosCargos: 0,
      })),
    }
  }

  return {
    ...common,
    fecComunicacion: formatLimaDateTime(proceso.fecha_comunicacion),
    details: details.map((detail: any) => ({
      tipoDoc: cleanText(detail.tipo_doc),
      serie: cleanText(detail.serie),
      correlativo: String(detail.correlativo),
      desMotivoBaja: cleanText(detail.motivo, 'ERROR EN EMISIÓN'),
    })),
  }
}

function endpoint(proceso: any): 'summary' | 'voided' {
  return proceso.tipo_proceso === 'resumen_boletas' ? 'summary' : 'voided'
}

function documentBasePath(proceso: any, config: any): string {
  const year = String(proceso.fecha_comunicacion || new Date().getUTCFullYear()).slice(0, 4)
  return `${cleanText(config.ruc, 'sin-ruc')}/${year}/procesos_tributarios/${cleanText(proceso.identificador)}`
}

async function saveXmlFromBody(
  admin: SupabaseClient,
  proceso: any,
  config: any,
  body: any,
): Promise<string | null> {
  const raw = body?.xml || body?.data?.xml
  if (typeof raw !== 'string' || !raw.trim()) return null
  try {
    const bytes = textOrBase64Bytes(raw)
    const ext = isZip(bytes) ? 'zip' : 'xml'
    return await uploadBytes(
      admin,
      `${documentBasePath(proceso, config)}/${proceso.identificador}.${ext}`,
      bytes,
      ext === 'zip' ? 'application/zip' : 'application/xml',
    )
  } catch (error) {
    console.error('No se pudo guardar el XML del proceso tributario', error)
    return null
  }
}

async function saveCdrFromBody(
  admin: SupabaseClient,
  proceso: any,
  config: any,
  body: any,
): Promise<string | null> {
  const raw = body?.cdrZip || body?.sunatResponse?.cdrZip
  if (typeof raw !== 'string' || !raw.trim()) return null
  try {
    return await uploadBytes(
      admin,
      `${documentBasePath(proceso, config)}/R-${proceso.identificador}.zip`,
      base64ToBytes(raw),
      'application/zip',
    )
  } catch (error) {
    console.error('No se pudo guardar el CDR del proceso tributario', error)
    return null
  }
}

async function generateDocument(
  admin: SupabaseClient,
  proceso: any,
  config: any,
  payload: any,
  type: 'xml' | 'pdf',
): Promise<string | null> {
  try {
    const response = await apiFetch(`/${endpoint(proceso)}/${type}`, {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    if (!response.ok) return null

    const contentType = (response.headers.get('content-type') || '').toLowerCase()
    let bytes: Uint8Array | null = null
    let ext: string = type

    if (type === 'pdf') {
      const rawBytes = new Uint8Array(await response.arrayBuffer())
      const hasPdfSignature =
        rawBytes.length >= 4 &&
        rawBytes[0] === 0x25 && rawBytes[1] === 0x50 &&
        rawBytes[2] === 0x44 && rawBytes[3] === 0x46
      if (
        contentType.includes('application/pdf') ||
        contentType.includes('application/octet-stream') ||
        hasPdfSignature
      ) {
        bytes = rawBytes
      } else {
        const text = new TextDecoder().decode(rawBytes).trim()
        if (text) {
          try {
            const body = JSON.parse(text)
            const raw = body?.pdf || body?.pdfBase64 || body?.data || body?.base64
            if (typeof raw === 'string' && raw.trim()) bytes = base64ToBytes(raw)
          } catch {
            // Una respuesta no JSON y sin firma PDF no se guarda.
          }
        }
      }
    } else {
      const body = await responseBody(response)
      const raw = body?.xml || body?.data || body?.base64 || body?.raw
      if (typeof raw === 'string' && raw.trim()) {
        bytes = textOrBase64Bytes(raw)
        if (isZip(bytes)) ext = 'zip'
      }
    }

    if (!bytes || bytes.length === 0) return null
    return uploadBytes(
      admin,
      `${documentBasePath(proceso, config)}/${proceso.identificador}.${ext}`,
      bytes,
      ext === 'pdf'
        ? 'application/pdf'
        : ext === 'zip'
          ? 'application/zip'
          : 'application/xml',
    )
  } catch (_) {
    return null
  }
}

async function claim(
  context: TributarioContext,
  procesoId: string,
  accion: 'emitir' | 'reintentar' | 'consultar',
  forzar = false,
): Promise<any> {
  const { data, error } = await context.admin.rpc('tributario_claim_proceso', {
    p_proceso_id: procesoId,
    p_usuario_id: context.user?.id ?? null,
    p_accion: accion,
    p_forzar: forzar,
    p_sistema: context.system,
  })
  if (error) throw new HttpError(409, error.message)
  return data
}

async function finalize(
  context: TributarioContext,
  procesoId: string,
  token: string,
  estado: string,
  result: Record<string, unknown>,
): Promise<any> {
  const { data, error } = await context.admin.rpc('tributario_finalizar_proceso', {
    p_proceso_id: procesoId,
    p_bloqueo_token: token,
    p_estado: estado,
    p_resultado: result,
  })
  if (error) throw new HttpError(500, error.message)
  return data
}

async function signedDocuments(
  admin: SupabaseClient,
  proceso: any,
): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  for (const [key, path] of Object.entries({
    pdf: proceso.pdf_path,
    xml: proceso.xml_path,
    cdr: proceso.cdr_path,
  })) {
    if (typeof path !== 'string' || !path.trim()) continue
    const { data, error } = await admin.storage
      .from(BUCKET)
      .createSignedUrl(path, 3600)
    if (!error && data?.signedUrl) result[key] = data.signedUrl
  }
  return result
}

function publicProceso(proceso: any, docs: Record<string, string>): any {
  return {
    id: proceso.id,
    tipo_proceso: proceso.tipo_proceso,
    fecha_referencia: proceso.fecha_referencia,
    fecha_comunicacion: proceso.fecha_comunicacion,
    correlativo: proceso.correlativo,
    identificador: proceso.identificador,
    estado: proceso.estado,
    ticket_sunat: proceso.ticket_sunat,
    codigo_sunat: proceso.codigo_sunat,
    descripcion_sunat: proceso.descripcion_sunat,
    observaciones_sunat: proceso.observaciones_sunat,
    numero_reintentos: proceso.numero_reintentos,
    ultimo_error_tipo: proceso.ultimo_error_tipo,
    ultimo_http_status: proceso.ultimo_http_status,
    ultimo_intento_at: proceso.ultimo_intento_at,
    enviado_at: proceso.enviado_at,
    aceptado_at: proceso.aceptado_at,
    detalles: proceso.procesos_tributarios_detalles || [],
    documentos: docs,
  }
}

export async function prepararProcesos(
  context: TributarioContext,
  tipoProceso: string | null,
  limite = 500,
): Promise<string[]> {
  const { data, error } = await context.admin.rpc('tributario_preparar_procesos', {
    p_tipo_proceso: tipoProceso,
    p_usuario_id: context.user?.id ?? null,
    p_sistema: context.system,
    p_limite_documentos: limite,
  })
  if (error) throw new HttpError(409, error.message)
  const ids = data?.proceso_ids
  return Array.isArray(ids) ? ids.map(String) : []
}

export async function emitirProcesoCore(options: {
  context: TributarioContext
  procesoId: string
  accion: 'emitir' | 'reintentar'
  forzar?: boolean
}): Promise<any> {
  const started = Date.now()
  const claimData = await claim(
    options.context,
    options.procesoId,
    options.accion,
    Boolean(options.forzar),
  )

  if (claimData?.claimed !== true) {
    const current = await fetchProceso(options.context.admin, options.procesoId)
    return {
      success: current.estado === 'aceptado',
      estado: current.estado,
      mensaje: claimData?.mensaje,
      proceso: publicProceso(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  }

  const lockToken = String(claimData.bloqueo_token)
  const intentoId = String(claimData.intento_id)
  let payload: any = null
  let remoteRequestStarted = false

  try {
    const proceso = await fetchProceso(options.context.admin, options.procesoId)
    const config = await company(options.context.admin)
    payload = buildPayload(proceso, config)

    await options.context.admin
      .from('procesos_tributarios')
      .update({ payload_json: payload })
      .eq('id', options.procesoId)
    await options.context.admin
      .from('procesos_tributarios_intentos')
      .update({ payload_json: payload })
      .eq('id', intentoId)

    remoteRequestStarted = true
    const response = await apiFetch(`/${endpoint(proceso)}/send`, {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    const body = await responseBody(response)
    const xmlPath = await saveXmlFromBody(
      options.context.admin,
      proceso,
      config,
      body,
    ) || await generateDocument(
      options.context.admin,
      proceso,
      config,
      payload,
      'xml',
    )
    const pdfPath = await generateDocument(
      options.context.admin,
      proceso,
      config,
      payload,
      'pdf',
    )
    const ticket = responseTicket(body)

    if (response.ok && isAccepted(body)) {
      const cdrPath = await saveCdrFromBody(
        options.context.admin,
        proceso,
        config,
        body,
      )
      await finalize(options.context, options.procesoId, lockToken, 'aceptado', {
        intento_id: intentoId,
        codigo_http: response.status,
        duracion_ms: Date.now() - started,
        payload_json: payload,
        respuesta_json: body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        ...(pdfPath ? { pdf_path: pdfPath } : {}),
        ...(cdrPath ? { cdr_path: cdrPath } : {}),
        ticket_sunat: ticket,
        hash_documento: cleanText(body?.hash),
        codigo_sunat: responseCode(body) || '0',
        descripcion_sunat: responseMessage(body, 'Aceptado por SUNAT'),
        observaciones_sunat: responseNotes(body),
      })
    } else if (response.ok && ticket) {
      await finalize(
        options.context,
        options.procesoId,
        lockToken,
        'ticket_pendiente',
        {
          intento_id: intentoId,
          codigo_http: response.status,
          duracion_ms: Date.now() - started,
          payload_json: payload,
          respuesta_json: body,
          ...(xmlPath ? { xml_path: xmlPath } : {}),
          ...(pdfPath ? { pdf_path: pdfPath } : {}),
          ticket_sunat: ticket,
          hash_documento: cleanText(body?.hash),
          descripcion_sunat: 'Enviado a SUNAT. Ticket pendiente de consulta',
        },
      )
    } else {
      const providerTechnical = isProviderTechnicalError(body)
      const definitiveValidation =
        [400, 422].includes(response.status) && !providerTechnical
      const providerPreSendFailure =
        [401, 403, 404, 429].includes(response.status)
      const state = definitiveValidation || providerPreSendFailure
        ? 'pendiente_reintento'
        : 'resultado_incierto'
      const message = responseMessage(
        body,
        state === 'pendiente_reintento'
          ? definitiveValidation
            ? 'El proveedor detectó errores de validación antes de entregar un ticket. Corrige los datos y vuelve a intentarlo.'
            : 'El proveedor rechazó la autenticación o limitó la solicitud antes de enviarla a SUNAT. Corrige la configuración y reintenta.'
          : 'No se recibió un resultado final del envío. El proceso debe reconciliarse antes de habilitar otro intento.',
      )
      await finalize(options.context, options.procesoId, lockToken, state, {
        intento_id: intentoId,
        codigo_http: response.status,
        duracion_ms: Date.now() - started,
        payload_json: payload,
        respuesta_json: body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        ...(pdfPath ? { pdf_path: pdfPath } : {}),
        codigo_error: responseCode(body),
        mensaje_error: message,
        descripcion_sunat: message,
        error_tipo: state === 'pendiente_reintento'
          ? (definitiveValidation
              ? 'validacion_proveedor'
              : 'configuracion_proveedor')
          : providerTechnical
          ? 'resultado_incierto_proveedor'
          : 'resultado_incierto',
      })
    }

    const current = await fetchProceso(options.context.admin, options.procesoId)
    return {
      success: current.estado === 'aceptado' || current.estado === 'ticket_pendiente',
      estado: current.estado,
      proceso: publicProceso(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const state = remoteRequestStarted
      ? 'resultado_incierto'
      : 'pendiente_reintento'
    const description = remoteRequestStarted
      ? 'No se recibió el resultado final del envío. El proceso debe reconciliarse antes de habilitar otro intento.'
      : 'El proceso no llegó a enviarse al proveedor. Corrige el problema y vuelve a intentarlo.'

    await finalize(
      options.context,
      options.procesoId,
      lockToken,
      state,
      {
        intento_id: intentoId,
        duracion_ms: Date.now() - started,
        ...(payload ? { payload_json: payload } : {}),
        mensaje_error: remoteRequestStarted
          ? `Resultado remoto incierto: ${message}`
          : message,
        descripcion_sunat: description,
        error_tipo: remoteRequestStarted
          ? (error instanceof DOMException && error.name === 'AbortError'
              ? 'resultado_incierto_timeout'
              : 'resultado_incierto_conexion')
          : 'validacion_local',
      },
    )
    const current = await fetchProceso(options.context.admin, options.procesoId)
    return {
      success: false,
      estado: state,
      mensaje: description,
      proceso: publicProceso(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  }
}

export async function consultarProcesoCore(options: {
  context: TributarioContext
  procesoId: string
  consultarSunat: boolean
}): Promise<any> {
  let proceso = await fetchProceso(options.context.admin, options.procesoId)

  if (
    options.consultarSunat &&
    proceso.estado !== 'aceptado' &&
    cleanText(proceso.ticket_sunat)
  ) {
    const claimData = await claim(
      options.context,
      options.procesoId,
      'consultar',
      false,
    )

    if (claimData?.claimed === true) {
      const started = Date.now()
      const lockToken = String(claimData.bloqueo_token)
      const intentoId = String(claimData.intento_id)
      try {
        const config = await company(options.context.admin)
        const params = new URLSearchParams({
          ticket: String(proceso.ticket_sunat),
          ruc: String(config.ruc),
        })
        const response = await apiFetch(
          `/${endpoint(proceso)}/status?${params.toString()}`,
          { method: 'GET', headers: {} },
          STATUS_TIMEOUT_MS,
        )
        const body = await responseBody(response)
        const cdrPath = await saveCdrFromBody(
          options.context.admin,
          proceso,
          config,
          body,
        )

        if (response.ok && isAccepted(body)) {
          const payload = proceso.payload_json || buildPayload(proceso, config)
          const xmlPath = proceso.xml_path || await generateDocument(
            options.context.admin,
            proceso,
            config,
            payload,
            'xml',
          )
          const pdfPath = proceso.pdf_path || await generateDocument(
            options.context.admin,
            proceso,
            config,
            payload,
            'pdf',
          )
          await finalize(options.context, options.procesoId, lockToken, 'aceptado', {
            intento_id: intentoId,
            codigo_http: response.status,
            duracion_ms: Date.now() - started,
            respuesta_json: body,
            ...(cdrPath ? { cdr_path: cdrPath } : {}),
            ...(xmlPath ? { xml_path: xmlPath } : {}),
            ...(pdfPath ? { pdf_path: pdfPath } : {}),
            codigo_sunat: responseCode(body) || '0',
            descripcion_sunat: responseMessage(body, 'Aceptado por SUNAT'),
            observaciones_sunat: responseNotes(body),
            fue_consulta: true,
          })
        } else if (
          (response.ok && isTicketStillProcessing(body)) ||
          isProviderTechnicalError(body)
        ) {
          const providerTechnical = isProviderTechnicalError(body)
          await finalize(
            options.context,
            options.procesoId,
            lockToken,
            'ticket_pendiente',
            {
              intento_id: intentoId,
              codigo_http: response.status,
              duracion_ms: Date.now() - started,
              respuesta_json: body,
              codigo_error: responseCode(body),
              descripcion_sunat: responseMessage(
                body,
                providerTechnical
                  ? 'El proveedor no pudo completar la consulta del ticket. Se conservará para una consulta posterior.'
                  : 'SUNAT continúa procesando el ticket',
              ),
              error_tipo: providerTechnical
                ? 'proveedor_temporal'
                : 'ticket_procesando',
              fue_consulta: true,
            },
          )
        } else {
          const temporary = isTemporaryHttp(response.status)
          const state = temporary ? 'ticket_pendiente' : 'rechazado'
          const message = responseMessage(
            body,
            temporary
              ? 'No fue posible consultar el ticket temporalmente'
              : 'SUNAT rechazó el proceso tributario',
          )
          await finalize(options.context, options.procesoId, lockToken, state, {
            intento_id: intentoId,
            codigo_http: response.status,
            duracion_ms: Date.now() - started,
            respuesta_json: body,
            ...(cdrPath ? { cdr_path: cdrPath } : {}),
            codigo_error: responseCode(body),
            mensaje_error: message,
            descripcion_sunat: message,
            error_tipo: temporary ? 'temporal_consulta' : 'sunat',
            fue_consulta: true,
          })
        }
      } catch (error) {
        const isTimeout =
          error instanceof DOMException && error.name === 'AbortError'
        const message = error instanceof Error ? error.message : String(error)

        // El ticket ya existe. Un timeout al CONSULTAR no significa que el
        // resumen deba enviarse nuevamente. Conservamos ticket_pendiente para
        // que el siguiente intento vuelva a consultar el mismo ticket.
        await finalize(
          options.context,
          options.procesoId,
          lockToken,
          'ticket_pendiente',
          {
            intento_id: intentoId,
            duracion_ms: Date.now() - started,
            mensaje_error: message,
            descripcion_sunat:
              'El ticket se conserva. La siguiente acción volverá a consultar el mismo ticket sin reenviar el proceso.',
            error_tipo: isTimeout ? 'timeout_consulta' : 'conexion_consulta',
            fue_consulta: true,
            ticket_sunat: proceso.ticket_sunat,
          },
        )
      }
      proceso = await fetchProceso(options.context.admin, options.procesoId)
    }
  }

  return {
    success: true,
    estado: proceso.estado,
    proceso: publicProceso(
      proceso,
      await signedDocuments(options.context.admin, proceso),
    ),
  }
}

export async function processPreparedIds(
  context: TributarioContext,
  ids: string[],
): Promise<any[]> {
  const results: any[] = []
  for (const id of ids) {
    try {
      results.push(await emitirProcesoCore({
        context,
        procesoId: id,
        accion: 'emitir',
      }))
    } catch (error) {
      results.push({
        success: false,
        proceso_id: id,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }
  return results
}

export async function retryPending(
  context: TributarioContext,
  limite = 20,
  tipoProceso?: string | null,
): Promise<any[]> {
  const safeLimit = Math.max(1, Math.min(limite, 100))
  const cooldownMs = 30 * 60 * 1000
  const maxAttempts = 30

  let query = context.admin
    .from('procesos_tributarios')
    .select(
      'id,estado,ticket_sunat,numero_reintentos,ultimo_intento_at',
    )
    .in('estado', [
      'pendiente_envio',
      'pendiente_reintento',
      'ticket_pendiente',
      'procesando',
    ])
    .order('ultimo_intento_at', { ascending: true, nullsFirst: true })
    .limit(Math.min(Math.max(safeLimit * 5, safeLimit), 500))

  if (tipoProceso) query = query.eq('tipo_proceso', tipoProceso)
  const { data, error } = await query
  if (error) throw new HttpError(500, error.message)

  const now = Date.now()
  const candidates = (data || [])
    .filter((row: any) => {
      const attempts = asNumber(row.numero_reintentos)
      if (attempts >= maxAttempts) return false

      const lastAttempt = cleanText(row.ultimo_intento_at)
      if (!lastAttempt) return true

      const timestamp = Date.parse(lastAttempt)
      return Number.isNaN(timestamp) || now - timestamp >= cooldownMs
    })
    .slice(0, safeLimit)

  const results: any[] = []
  for (const row of candidates) {
    try {
      if (cleanText(row.ticket_sunat)) {
        results.push(await consultarProcesoCore({
          context,
          procesoId: String(row.id),
          consultarSunat: true,
        }))
      } else {
        results.push(await emitirProcesoCore({
          context,
          procesoId: String(row.id),
          accion: 'reintentar',
        }))
      }
    } catch (error) {
      results.push({
        success: false,
        proceso_id: row.id,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  await context.admin.rpc('tributario_reintentar_stock_bajas', {
    p_limite: safeLimit,
  })
  return results
}

export function errorResponse(error: unknown): Response {
  const status = error instanceof HttpError ? error.status : 500
  const message = error instanceof Error ? error.message : String(error)
  return jsonResponse(
    {
      success: false,
      error: message,
      ...(error instanceof HttpError && error.details
        ? { details: error.details }
        : {}),
    },
    status,
  )
}