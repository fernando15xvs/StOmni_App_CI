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

export type NotaCreditoContext = {
  admin: SupabaseClient
  user: User | null
  system: boolean
  employee: EmployeeIdentity | null
}

type EmitOptions = {
  notaCreditoId: string
  accion: 'emitir' | 'reintentar'
  forzar?: boolean
  context: NotaCreditoContext
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
  allowedRoles: readonly AppRole[] = ['admin', 'operador'],
): Promise<NotaCreditoContext> {
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

function round(value: number, decimals = 2): number {
  const factor = 10 ** decimals
  return Math.round((value + Number.EPSILON) * factor) / factor
}

function asNumber(value: unknown, fallback = 0): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function asInt(value: unknown, fallback = 0): number {
  return Math.trunc(asNumber(value, fallback))
}

function cleanText(value: unknown, fallback = ''): string {
  const text = String(value ?? '').trim()
  return text || fallback
}

function formatLimaDateTime(value: unknown): string {
  const source = value ? new Date(String(value)) : new Date()
  const lima = new Date(source.getTime() - 5 * 60 * 60 * 1000)
  const yyyy = lima.getUTCFullYear()
  const mm = String(lima.getUTCMonth() + 1).padStart(2, '0')
  const dd = String(lima.getUTCDate()).padStart(2, '0')
  const hh = String(lima.getUTCHours()).padStart(2, '0')
  const min = String(lima.getUTCMinutes()).padStart(2, '0')
  const ss = String(lima.getUTCSeconds()).padStart(2, '0')
  return `${yyyy}-${mm}-${dd}T${hh}:${min}:${ss}-05:00`
}

/**
 * Convierte una fecha a un número de día calendario de Lima.
 * Los valores DATE (YYYY-MM-DD) se preservan sin reinterpretarlos como UTC.
 */
function limaCalendarDay(value: unknown): number | null {
  const raw = cleanText(value)
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw)
  if (dateOnly) {
    const year = Number(dateOnly[1])
    const month = Number(dateOnly[2])
    const day = Number(dateOnly[3])
    return Math.floor(Date.UTC(year, month - 1, day) / 86_400_000)
  }

  const parsed = raw ? new Date(raw) : new Date()
  if (Number.isNaN(parsed.getTime())) return null
  const lima = new Date(parsed.getTime() - 5 * 60 * 60 * 1000)
  return Math.floor(Date.UTC(
    lima.getUTCFullYear(),
    lima.getUTCMonth(),
    lima.getUTCDate(),
  ) / 86_400_000)
}

function sunatSendDeadlineExpired(
  emissionValue: unknown,
  maxFollowingCalendarDays = 3,
): boolean {
  const emissionDay = limaCalendarDay(emissionValue)
  const todayLima = limaCalendarDay(new Date().toISOString())
  if (emissionDay === null || todayLima === null) return false
  return todayLima > emissionDay + maxFollowingCalendarDays
}

function integerWords(value: number): string {
  const units = [
    '',
    'UNO',
    'DOS',
    'TRES',
    'CUATRO',
    'CINCO',
    'SEIS',
    'SIETE',
    'OCHO',
    'NUEVE',
    'DIEZ',
    'ONCE',
    'DOCE',
    'TRECE',
    'CATORCE',
    'QUINCE',
    'DIECISEIS',
    'DIECISIETE',
    'DIECIOCHO',
    'DIECINUEVE',
    'VEINTE',
  ]
  const tens = [
    '',
    '',
    'VEINTE',
    'TREINTA',
    'CUARENTA',
    'CINCUENTA',
    'SESENTA',
    'SETENTA',
    'OCHENTA',
    'NOVENTA',
  ]
  const hundreds = [
    '',
    'CIENTO',
    'DOSCIENTOS',
    'TRESCIENTOS',
    'CUATROCIENTOS',
    'QUINIENTOS',
    'SEISCIENTOS',
    'SETECIENTOS',
    'OCHOCIENTOS',
    'NOVECIENTOS',
  ]

  const underThousand = (n: number): string => {
    if (n === 0) return ''
    if (n === 100) return 'CIEN'
    if (n < units.length) return units[n]
    if (n < 30) return `VEINTI${units[n - 20].toLowerCase()}`.toUpperCase()
    if (n < 100) {
      const d = Math.floor(n / 10)
      const u = n % 10
      return u === 0 ? tens[d] : `${tens[d]} Y ${units[u]}`
    }
    const h = Math.floor(n / 100)
    const rest = n % 100
    return rest === 0 ? hundreds[h] : `${hundreds[h]} ${underThousand(rest)}`
  }

  if (value === 0) return 'CERO'
  if (value < 1000) return underThousand(value)
  if (value < 1_000_000) {
    const thousands = Math.floor(value / 1000)
    const rest = value % 1000
    const prefix = thousands === 1
      ? 'MIL'
      : `${underThousand(thousands)} MIL`
    return rest === 0 ? prefix : `${prefix} ${underThousand(rest)}`
  }
  if (value < 1_000_000_000) {
    const millions = Math.floor(value / 1_000_000)
    const rest = value % 1_000_000
    const prefix = millions === 1
      ? 'UN MILLON'
      : `${integerWords(millions)} MILLONES`
    return rest === 0 ? prefix : `${prefix} ${integerWords(rest)}`
  }
  return String(value)
}

function amountLegend(value: number): string {
  const safe = Math.max(0, round(value, 2))
  const integer = Math.floor(safe)
  const cents = Math.round((safe - integer) * 100)
  return `SON ${integerWords(integer)} CON ${String(cents).padStart(2, '0')}/100 SOLES`
}

function responseMessage(body: any, fallback: string): string {
  const error = body?.sunatResponse?.error || body?.error
  return cleanText(
    body?.cdrResponse?.description ||
      body?.sunatResponse?.cdrResponse?.description ||
      error?.message ||
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
  const notes = body?.cdrResponse?.notes ||
    body?.sunatResponse?.cdrResponse?.notes
  return Array.isArray(notes) ? notes : []
}

function finalCdr(body: any): any | null {
  const cdr = body?.cdrResponse || body?.sunatResponse?.cdrResponse
  if (!cdr || typeof cdr !== 'object') return null
  const code = cleanText(cdr?.code)
  if (typeof cdr?.accepted === 'boolean' || code.length > 0) return cdr
  return null
}

function isAccepted(body: any): boolean {
  const cdr = finalCdr(body)
  if (!cdr) return false
  if (cdr.accepted === true) return true
  if (cdr.accepted === false) return false
  return cleanText(cdr.code) === '0'
}

function isFinalRejected(body: any): boolean {
  const cdr = finalCdr(body)
  return cdr !== null && !isAccepted(body)
}

function isProviderTechnicalError(body: any): boolean {
  if (finalCdr(body)) return false
  const message = responseMessage(body, '').toLowerCase()
  return (
    message.includes('failed to process response headers') ||
    message.includes('error al comunicarse') ||
    message.includes('servidor interno') ||
    message.includes('internal server') ||
    message.includes('connection') ||
    message.includes('timeout') ||
    message.includes('temporarily unavailable') ||
    message.includes('unauthorized') ||
    message.includes('token') ||
    message.includes('credencial')
  )
}

function isDefinitiveValidationStatus(httpStatus: number): boolean {
  return httpStatus === 400 || httpStatus === 422
}

function isProviderPreSendFailure(httpStatus: number): boolean {
  return [401, 403, 404, 429].includes(httpStatus)
}

function base64ToBytes(raw: string): Uint8Array {
  const normalized = raw.replace(/^data:[^;]+;base64,/, '').trim()
  const binary = atob(normalized)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes
}

function textOrBase64Bytes(raw: string): Uint8Array {
  const trimmed = raw.trim()
  if (trimmed.startsWith('<') || trimmed.startsWith('<?xml')) {
    return new TextEncoder().encode(trimmed)
  }
  return base64ToBytes(trimmed)
}

function isZip(bytes: Uint8Array): boolean {
  return bytes.length >= 2 && bytes[0] === 0x50 && bytes[1] === 0x4b
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

function documentBasePath(nota: any): string {
  const date = new Date(
    nota.fecha_emision_ts || `${nota.fecha_emision}T12:00:00-05:00`,
  )
  const year = Number.isNaN(date.getTime())
    ? new Date().getUTCFullYear()
    : date.getUTCFullYear()
  return `${cleanText(nota.empresa_ruc, 'sin-ruc')}/${year}/nota_credito/${nota.serie}-${nota.correlativo}`
}

async function saveApiDocuments(
  admin: SupabaseClient,
  nota: any,
  body: any,
): Promise<Record<string, string>> {
  const base = documentBasePath(nota)
  const result: Record<string, string> = {}

  const xmlRaw = body?.xml
  if (typeof xmlRaw === 'string' && xmlRaw.trim()) {
    try {
      const bytes = textOrBase64Bytes(xmlRaw)
      const ext = isZip(bytes) ? 'zip' : 'xml'
      result.xml_path = await uploadBytes(
        admin,
        `${base}/${nota.serie}-${nota.correlativo}.${ext}`,
        bytes,
        ext === 'zip' ? 'application/zip' : 'application/xml',
      )
    } catch (error) {
      console.error('No se pudo guardar el XML de la nota', error)
    }
  }

  const cdrRaw = body?.cdrZip || body?.sunatResponse?.cdrZip
  if (typeof cdrRaw === 'string' && cdrRaw.trim()) {
    try {
      result.cdr_path = await uploadBytes(
        admin,
        `${base}/R-${nota.serie}-${nota.correlativo}.zip`,
        base64ToBytes(cdrRaw),
        'application/zip',
      )
    } catch (error) {
      console.error('No se pudo guardar el CDR de la nota', error)
    }
  }

  return result
}

async function apiFetch(path: string, init: RequestInit): Promise<Response> {
  const token = requiredEnv('APIS_PERU_TOKEN')
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS)

  try {
    return await fetch(`${apiBaseUrl()}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
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

async function generateDocument(
  admin: SupabaseClient,
  nota: any,
  payload: any,
  kind: 'pdf' | 'xml',
): Promise<string | null> {
  try {
    const response = await apiFetch(`/note/${kind}`, {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    if (!response.ok) return null

    if (kind === 'pdf') {
      const contentType = (response.headers.get('content-type') || '').toLowerCase()
      const rawBytes = new Uint8Array(await response.arrayBuffer())
      let bytes: Uint8Array | null = null
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
            const candidate = body?.pdf || body?.pdfBase64 || body?.base64 || body?.data
            if (typeof candidate === 'string' && candidate.trim()) {
              bytes = base64ToBytes(candidate)
            }
          } catch {
            // Una respuesta no JSON y sin firma PDF no se guarda.
          }
        }
      }

      if (!bytes || bytes.length === 0) return null
      return uploadBytes(
        admin,
        `${documentBasePath(nota)}/${nota.serie}-${nota.correlativo}.pdf`,
        bytes,
        'application/pdf',
      )
    }

    const body = await responseBody(response)
    const candidate = body?.xml || body?.base64 || body?.data || body?.raw
    if (typeof candidate !== 'string' || !candidate.trim()) return null
    const bytes = textOrBase64Bytes(candidate)
    const ext = isZip(bytes) ? 'zip' : 'xml'
    return uploadBytes(
      admin,
      `${documentBasePath(nota)}/${nota.serie}-${nota.correlativo}.${ext}`,
      bytes,
      ext === 'zip' ? 'application/zip' : 'application/xml',
    )
  } catch (_) {
    return null
  }
}

async function fetchNota(
  admin: SupabaseClient,
  notaCreditoId: string,
): Promise<any> {
  const { data, error } = await admin
    .from('notas_credito')
    .select(`
      *,
      notas_credito_detalles(*)
    `)
    .eq('id', notaCreditoId)
    .single()

  if (error || !data) {
    throw new HttpError(404, 'Nota de crédito no encontrada', error?.message)
  }
  return data
}

function buildPayload(nota: any): any {
  const rawDetails = Array.isArray(nota.notas_credito_detalles)
    ? nota.notas_credito_detalles
    : []
  if (rawDetails.length === 0) {
    throw new HttpError(409, 'La nota no contiene detalles')
  }

  const details = rawDetails.map((detail: any) => {
    const commercialQuantity = asNumber(detail.commercial_quantity_snapshot)
    const usesCommercialSnapshot = commercialQuantity > 0
    const quantity = usesCommercialSnapshot
      ? commercialQuantity
      : Math.max(1, asInt(detail.cantidad_visual, 1))
    const unit = usesCommercialSnapshot
      ? cleanText(detail.fiscal_unit_code_snapshot).toUpperCase()
      : cleanText(detail.unidad_sunat, 'NIU')
    if (usesCommercialSnapshot && !/^[A-Z0-9]{1,6}$/.test(unit)) {
      throw new HttpError(
        409,
        `La nota contiene una presentación configurable sin código fiscal válido: ${cleanText(detail.descripcion_original, 'PRODUCTO')}. Configura la unidad fiscal antes de emitir.`,
      )
    }
    const total = round(asNumber(detail.subtotal), 2)
    const base = round(asNumber(detail.base_imponible, total / 1.18), 2)
    const igv = round(asNumber(detail.igv, total - base), 2)
    const description = cleanText(
      detail.descripcion_corregida || detail.descripcion_original,
      'PRODUCTO',
    )

    return {
      codProducto: cleanText(detail.codigo_producto, 'NC'),
      unidad: unit,
      descripcion: description,
      cantidad: quantity,
      mtoValorUnitario: round(base / quantity, 6),
      mtoValorVenta: base,
      mtoBaseIgv: base,
      porcentajeIgv: 18,
      igv,
      tipAfeIgv: 10,
      totalImpuestos: igv,
      mtoPrecioUnitario: round(total / quantity, 6),
    }
  })

  const targetBase = round(asNumber(nota.base_imponible), 2)
  const targetIgv = round(asNumber(nota.igv), 2)
  const targetTotal = round(asNumber(nota.total), 2)

  const baseSum = round(
    details.reduce((sum: number, detail: any) => sum + detail.mtoValorVenta, 0),
    2,
  )
  const igvSum = round(
    details.reduce((sum: number, detail: any) => sum + detail.igv, 0),
    2,
  )
  const last = details[details.length - 1]
  if (last) {
    last.mtoValorVenta = round(last.mtoValorVenta + targetBase - baseSum, 2)
    last.mtoBaseIgv = last.mtoValorVenta
    last.igv = round(last.igv + targetIgv - igvSum, 2)
    last.totalImpuestos = last.igv
    last.mtoValorUnitario = round(last.mtoValorVenta / last.cantidad, 6)
    last.mtoPrecioUnitario = round(
      (last.mtoValorVenta + last.igv) / last.cantidad,
      6,
    )
  }

  const client: Record<string, unknown> = {
    tipoDoc: cleanText(nota.cliente_tipo_documento, '0'),
    numDoc: cleanText(nota.cliente_numero_documento, '0'),
    rznSocial: cleanText(nota.cliente_razon_social, 'CLIENTE GENERAL'),
  }
  const clientAddress = cleanText(nota.cliente_direccion)
  if (clientAddress) client.address = { direccion: clientAddress }

  return {
    ublVersion: '2.1',
    tipoDoc: '07',
    serie: cleanText(nota.serie),
    correlativo: String(nota.correlativo),
    fechaEmision: formatLimaDateTime(
      nota.fecha_emision_ts || nota.fecha_emision,
    ),
    tipDocAfectado: cleanText(nota.tipo_doc_afectado),
    // APIsPERU usa este nombre exacto en su esquema actual.
    numDocfectado:
      `${cleanText(nota.serie_afectada)}-${nota.correlativo_afectado}`,
    codMotivo: cleanText(nota.motivo_codigo),
    desMotivo: cleanText(nota.motivo_descripcion),
    tipoMoneda: cleanText(nota.moneda, 'PEN'),
    client,
    company: {
      ruc: cleanText(nota.empresa_ruc),
      razonSocial: cleanText(nota.empresa_razon_social),
      nombreComercial: cleanText(
        nota.empresa_nombre_comercial,
        nota.empresa_razon_social,
      ),
      address: {
        direccion: cleanText(nota.empresa_direccion),
        provincia: cleanText(nota.empresa_provincia),
        departamento: cleanText(nota.empresa_departamento),
        distrito: cleanText(nota.empresa_distrito),
        ubigueo: cleanText(nota.empresa_ubigeo),
        codLocal: cleanText(nota.empresa_cod_local, '0000'),
      },
    },
    mtoOperGravadas: targetBase,
    mtoIGV: targetIgv,
    valorVenta: targetBase,
    totalImpuestos: targetIgv,
    subTotal: targetTotal,
    mtoImpVenta: targetTotal,
    details,
    legends: [{ code: '1000', value: amountLegend(targetTotal) }],
    name:
      `${cleanText(nota.empresa_ruc)}-07-${nota.serie}-${nota.correlativo}`,
  }
}

async function claim(
  context: NotaCreditoContext,
  notaCreditoId: string,
  accion: string,
  forzar: boolean,
): Promise<any> {
  const { data, error } = await context.admin.rpc('nota_credito_claim', {
    p_nota_credito_id: notaCreditoId,
    p_usuario_id: context.user?.id ?? null,
    p_accion: accion,
    p_forzar: forzar,
    p_sistema: context.system,
  })
  if (error) throw new HttpError(409, error.message)
  return data
}

async function finalize(
  context: NotaCreditoContext,
  notaCreditoId: string,
  bloqueoToken: string,
  estado: string,
  resultado: Record<string, unknown>,
): Promise<any> {
  const { data, error } = await context.admin.rpc('nota_credito_finalizar', {
    p_nota_credito_id: notaCreditoId,
    p_bloqueo_token: bloqueoToken,
    p_estado: estado,
    p_resultado: resultado,
  })
  if (error) throw new HttpError(500, error.message)
  return data
}

async function signedDocuments(
  admin: SupabaseClient,
  nota: any,
): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  for (const [key, path] of Object.entries({
    pdf: nota.pdf_path,
    xml: nota.xml_path,
    cdr: nota.cdr_path,
  })) {
    if (typeof path !== 'string' || !path.trim()) continue
    const { data, error } = await admin.storage
      .from(BUCKET)
      .createSignedUrl(path, 3600)
    if (!error && data?.signedUrl) result[key] = data.signedUrl
  }
  return result
}

function publicNota(nota: any, documentos: Record<string, string>): any {
  return {
    id: nota.id,
    venta_id: nota.venta_id,
    comprobante_id: nota.comprobante_id,
    serie: nota.serie,
    correlativo: nota.correlativo,
    tipo_doc_afectado: nota.tipo_doc_afectado,
    serie_afectada: nota.serie_afectada,
    correlativo_afectado: nota.correlativo_afectado,
    motivo_codigo: nota.motivo_codigo,
    motivo_descripcion: nota.motivo_descripcion,
    fecha_emision: nota.fecha_emision,
    estado: nota.estado,
    total: nota.total,
    codigo_sunat: nota.codigo_sunat,
    descripcion_sunat: nota.descripcion_sunat,
    observaciones_sunat: nota.observaciones_sunat,
    numero_reintentos: nota.numero_reintentos,
    ultimo_error_tipo: nota.ultimo_error_tipo,
    ultimo_http_status: nota.ultimo_http_status,
    aceptado_at: nota.aceptado_at,
    reponer_stock: nota.reponer_stock,
    stock_aplicado: nota.stock_aplicado,
    stock_error: nota.stock_error,
    stock_reintentos: nota.stock_reintentos,
    stock_ultimo_intento_at: nota.stock_ultimo_intento_at,
    estado_baja_tributaria: nota.estado_baja_tributaria,
    solicitud_baja_id: nota.solicitud_baja_id,
    baja_motivo: nota.baja_motivo,
    baja_aceptada_at: nota.baja_aceptada_at,
    baja_stock_revertido: nota.baja_stock_revertido,
    baja_stock_error: nota.baja_stock_error,
    baja_stock_reintentos: nota.baja_stock_reintentos,
    baja_stock_ultimo_intento_at: nota.baja_stock_ultimo_intento_at,
    detalles: nota.notas_credito_detalles || [],
    documentos,
  }
}

export async function consultarNotaCreditoCore(
  context: NotaCreditoContext,
  notaCreditoId: string,
): Promise<any> {
  let nota = await fetchNota(context.admin, notaCreditoId)

  // La aceptación SUNAT es irreversible. Si la reposición local falló,
  // consultar el detalle vuelve a intentarla de forma idempotente.
  if (nota.estado === 'aceptado' &&
    nota.reponer_stock === true &&
    nota.stock_aplicado !== true) {
    await context.admin.rpc('_aplicar_stock_nota_credito', {
      p_nota_credito_id: notaCreditoId,
    })
    nota = await fetchNota(context.admin, notaCreditoId)
  }

  return {
    success: nota.estado === 'aceptado',
    estado: nota.estado,
    nota_credito: publicNota(
      nota,
      await signedDocuments(context.admin, nota),
    ),
  }
}

export async function emitirNotaCreditoCore(
  options: EmitOptions,
): Promise<any> {
  const started = Date.now()

  const preflight = await fetchNota(
    options.context.admin,
    options.notaCreditoId,
  )
  if (cleanText(preflight.tipo_doc_afectado) === '01' &&
    sunatSendDeadlineExpired(
      preflight.fecha_emision_ts || preflight.fecha_emision,
    )) {
    const message =
      'El plazo máximo de envío de esta nota vinculada a factura ya venció. No se realizó un nuevo envío. Verifica su validez antes de resolverla manualmente.'
    return {
      success: false,
      estado: preflight.estado,
      bloqueado_por_plazo: true,
      mensaje: message,
      nota_credito: publicNota(
        preflight,
        await signedDocuments(options.context.admin, preflight),
      ),
    }
  }

  const claimData = await claim(
    options.context,
    options.notaCreditoId,
    options.accion,
    Boolean(options.forzar),
  )

  if (claimData?.claimed !== true) {
    const current = await fetchNota(
      options.context.admin,
      options.notaCreditoId,
    )
    return {
      success: current.estado === 'aceptado',
      estado: current.estado,
      mensaje: claimData?.mensaje,
      nota_credito: publicNota(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  }

  const bloqueoToken = String(claimData.bloqueo_token)
  const intentoId = String(claimData.intento_id)
  let payload: any = null
  let remoteRequestStarted = false

  try {
    const nota = await fetchNota(options.context.admin, options.notaCreditoId)
    payload = buildPayload(nota)

    await options.context.admin
      .from('notas_credito_intentos')
      .update({ payload_json: payload })
      .eq('id', intentoId)

    await options.context.admin
      .from('notas_credito')
      .update({
        payload_json: payload,
        archivo_nombre_base: payload.name,
      })
      .eq('id', options.notaCreditoId)

    remoteRequestStarted = true
    const response = await apiFetch('/note/send', {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    const body = await responseBody(response)
    const docs = await saveApiDocuments(options.context.admin, nota, body)

    if (response.ok && isAccepted(body)) {
      const pdfPath = await generateDocument(
        options.context.admin,
        nota,
        payload,
        'pdf',
      )
      const xmlPath = docs.xml_path || await generateDocument(
        options.context.admin,
        nota,
        payload,
        'xml',
      )

      const result = await finalize(
        options.context,
        options.notaCreditoId,
        bloqueoToken,
        'aceptado',
        {
          intento_id: intentoId,
          codigo_http: response.status,
          duracion_ms: Date.now() - started,
          payload_json: payload,
          respuesta_json: body,
          ...docs,
          ...(xmlPath ? { xml_path: xmlPath } : {}),
          ...(pdfPath ? { pdf_path: pdfPath } : {}),
          hash_documento: cleanText(body?.hash),
          codigo_sunat: responseCode(body) || '0',
          descripcion_sunat: responseMessage(
            body,
            'Nota de crédito aceptada por SUNAT',
          ),
          observaciones_sunat: responseNotes(body),
          ticket_sunat: cleanText(body?.sunatResponse?.ticket),
          archivo_nombre_base: payload.name,
        },
      )

      const current = await fetchNota(
        options.context.admin,
        options.notaCreditoId,
      )
      return {
        ...result,
        nota_credito: publicNota(
          current,
          await signedDocuments(options.context.admin, current),
        ),
      }
    }

    const rejectedByCdr = isFinalRejected(body)
    const hasCdr = finalCdr(body) !== null
    const providerTechnical = isProviderTechnicalError(body)
    const definitiveValidation =
      isDefinitiveValidationStatus(response.status) && !providerTechnical
    const providerPreSendFailure =
      isProviderPreSendFailure(response.status) && !hasCdr
    const state = rejectedByCdr
      ? 'rechazado'
      : definitiveValidation || providerPreSendFailure
      ? 'pendiente_reintento'
      : 'resultado_incierto'
    const message = responseMessage(
      body,
      state === 'resultado_incierto'
        ? 'No se recibió un CDR final. No reenvíes la nota hasta revisar su validez en SUNAT o con el proveedor.'
        : state === 'pendiente_reintento'
        ? definitiveValidation
          ? 'El proveedor detectó errores de validación antes de obtener un CDR. Corrige los datos y vuelve a intentarlo.'
          : 'El proveedor rechazó la autenticación o limitó la solicitud antes de enviarla a SUNAT. Corrige la configuración y reintenta.'
        : 'La nota de crédito fue rechazada por un CDR definitivo de SUNAT.',
    )

    await finalize(
      options.context,
      options.notaCreditoId,
      bloqueoToken,
      state,
      {
        intento_id: intentoId,
        codigo_http: response.status,
        duracion_ms: Date.now() - started,
        payload_json: payload,
        respuesta_json: body,
        ...docs,
        codigo_error: responseCode(body),
        mensaje_error: message,
        descripcion_sunat: message,
        error_tipo: state === 'resultado_incierto'
          ? (providerTechnical
              ? 'resultado_incierto_proveedor'
              : 'resultado_incierto')
          : state === 'pendiente_reintento'
          ? (definitiveValidation
              ? 'validacion_proveedor'
              : 'configuracion_proveedor')
          : 'sunat',
        archivo_nombre_base: payload.name,
      },
    )

    const current = await fetchNota(
      options.context.admin,
      options.notaCreditoId,
    )
    return {
      success: false,
      estado: state,
      mensaje: message,
      nota_credito: publicNota(
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
      ? 'No se recibió el resultado final del envío. La nota debe reconciliarse antes de habilitar un nuevo intento.'
      : 'La nota no llegó a enviarse al proveedor. Corrige el problema y vuelve a intentarlo.'

    await finalize(
      options.context,
      options.notaCreditoId,
      bloqueoToken,
      state,
      {
        intento_id: intentoId,
        duracion_ms: Date.now() - started,
        ...(payload ? { payload_json: payload } : {}),
        mensaje_error: remoteRequestStarted
          ? 'Resultado remoto incierto: ' + message
          : message,
        descripcion_sunat: description,
        error_tipo: remoteRequestStarted
          ? (error instanceof DOMException && error.name === 'AbortError'
              ? 'resultado_incierto_timeout'
              : 'resultado_incierto_conexion')
          : 'validacion_local',
      },
    )
    const current = await fetchNota(options.context.admin, options.notaCreditoId)
    return {
      success: false,
      estado: state,
      mensaje: description,
      nota_credito: publicNota(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  }
}
