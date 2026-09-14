import { SupabaseClient, User } from 'https://esm.sh/@supabase/supabase-js@2.49.4'
import {
  AppRole,
  AuthGuardError,
  EmployeeIdentity,
  requireEmployee
} from './auth_guard.ts'

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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

export type FacturacionContext = {
  admin: SupabaseClient
  user: User | null
  system: boolean
  employee: EmployeeIdentity | null
}

type EmitOptions = {
  comprobanteId: string
  accion: 'emitir' | 'reintentar'
  forzar?: boolean
  context: FacturacionContext
}

type ConsultOptions = {
  comprobanteId: string
  consultarSunat: boolean
  context: FacturacionContext
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
): Promise<FacturacionContext> {
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
  const lima = new Date(source.getTime() - (5 * 60 * 60 * 1000))
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

function unitCode(tipoUnidad: unknown): string {
  switch (cleanText(tipoUnidad).toLowerCase()) {
    case 'caja':
    case 'cajas':
      return 'BX'
    case 'paquete':
    case 'paquetes':
      return 'PK'
    default:
      return 'NIU'
  }
}

type FiscalPresentation = {
  quantity: number
  unitCode: string
  description: string
}

function configuredFiscalPresentation(
  detail: Record<string, unknown>,
  product: Record<string, unknown>,
): FiscalPresentation | null {
  const raw = detail.presentation_snapshot
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const snapshot = raw as Record<string, unknown>
  if (asInt(snapshot.schema_version) !== 2) return null

  const quantity = asNumber(snapshot.quantity)
  const presentationCode = cleanText(snapshot.code)
  const profileRaw = snapshot.profile
  if (quantity <= 0 || !presentationCode || !profileRaw || typeof profileRaw !== 'object' || Array.isArray(profileRaw)) {
    throw new HttpError(409, `Snapshot de presentación inválido para ${cleanText(product.nombre, 'producto')}`)
  }

  const profile = profileRaw as Record<string, unknown>
  const rows = Array.isArray(profile.presentations) ? profile.presentations : []
  const presentation = rows.find((row: any) => cleanText(row?.code) === presentationCode) as Record<string, unknown> | undefined
  if (!presentation) {
    throw new HttpError(409, `La presentación fiscal de ${cleanText(product.nombre, 'producto')} no existe en su snapshot`)
  }

  const fiscalUnitCode = cleanText(presentation.fiscal_unit_code).toUpperCase()
  if (!/^[A-Z0-9]{1,6}$/.test(fiscalUnitCode)) {
    throw new HttpError(
      409,
      `La presentación ${cleanText(presentation.singular, presentationCode)} de ${cleanText(product.nombre, 'producto')} no tiene un código fiscal válido. Configúralo antes de emitir boleta o factura.`,
    )
  }

  const singular = cleanText(presentation.singular, presentationCode)
  const plural = cleanText(presentation.plural, singular)
  const label = Math.abs(quantity - 1) < 0.000001 ? singular : plural
  return {
    quantity,
    unitCode: fiscalUnitCode,
    description: `${cleanText(product.nombre, 'Producto')} - ${label}`,
  }
}

function presentationDescription(detail: Record<string, unknown>, product: Record<string, unknown>): string {
  const name = cleanText(product.nombre, 'Producto')
  const tipoUnidad = cleanText(detail.tipo_unidad).toLowerCase()
  const tipoVenta = cleanText(detail.tipo_venta_snapshot || product.tipo_venta).toUpperCase()
  const pcs = Math.max(1, asInt(detail.pcs_snapshot || product.cantidad_por_caja, 1))

  if (tipoUnidad === 'caja') {
    if (tipoVenta === 'CAJA_PAQUETES') return `${name} - Caja x ${pcs} paquetes`
    if (tipoVenta === 'CAJA_UNIDADES' || tipoVenta === 'AMBOS') {
      return `${name} - Caja x ${pcs} unidades`
    }
    return `${name} - Caja`
  }

  if (tipoUnidad === 'paquete') {
    if (tipoVenta === 'PAQUETES' || tipoVenta === 'PAQUETE') {
      return `${name} - Paquete x ${pcs} piezas`
    }
    return `${name} - Paquete`
  }

  return `${name} - Unidad`
}

function integerWords(value: number): string {
  const units = [
    '', 'UNO', 'DOS', 'TRES', 'CUATRO', 'CINCO', 'SEIS', 'SIETE', 'OCHO', 'NUEVE',
    'DIEZ', 'ONCE', 'DOCE', 'TRECE', 'CATORCE', 'QUINCE', 'DIECISEIS',
    'DIECISIETE', 'DIECIOCHO', 'DIECINUEVE', 'VEINTE',
  ]
  const tens = ['', '', 'VEINTE', 'TREINTA', 'CUARENTA', 'CINCUENTA', 'SESENTA', 'SETENTA', 'OCHENTA', 'NOVENTA']
  const hundreds = ['', 'CIENTO', 'DOSCIENTOS', 'TRESCIENTOS', 'CUATROCIENTOS', 'QUINIENTOS', 'SEISCIENTOS', 'SETECIENTOS', 'OCHOCIENTOS', 'NOVECIENTOS']

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
    const prefix = thousands === 1 ? 'MIL' : `${underThousand(thousands)} MIL`
    return rest === 0 ? prefix : `${prefix} ${underThousand(rest)}`
  }
  if (value < 1_000_000_000) {
    const millions = Math.floor(value / 1_000_000)
    const rest = value % 1_000_000
    const prefix = millions === 1 ? 'UN MILLON' : `${integerWords(millions)} MILLONES`
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
  const notes = body?.cdrResponse?.notes || body?.sunatResponse?.cdrResponse?.notes
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
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
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

function documentBasePath(comp: any): string {
  const date = new Date(comp.fecha_emision_ts || `${comp.fecha_emision}T12:00:00-05:00`)
  const year = Number.isNaN(date.getTime()) ? new Date().getUTCFullYear() : date.getUTCFullYear()
  const type = cleanText(comp.tipo_documento_sunat, 'comprobante').toLowerCase()
  return `${cleanText(comp.empresa_ruc, 'sin-ruc')}/${year}/${type}/${comp.serie}-${comp.correlativo}`
}

async function saveApiDocuments(admin: SupabaseClient, comp: any, body: any): Promise<Record<string, string>> {
  const base = documentBasePath(comp)
  const result: Record<string, string> = {}

  const xmlRaw = body?.xml
  if (typeof xmlRaw === 'string' && xmlRaw.trim()) {
    try {
      const bytes = textOrBase64Bytes(xmlRaw)
      const ext = isZip(bytes) ? 'zip' : 'xml'
      result.xml_path = await uploadBytes(
        admin,
        `${base}/${comp.serie}-${comp.correlativo}.${ext}`,
        bytes,
        ext === 'zip' ? 'application/zip' : 'application/xml',
      )
    } catch (error) {
      console.error('No se pudo guardar el XML del comprobante', error)
    }
  }

  const cdrRaw = body?.cdrZip || body?.sunatResponse?.cdrZip
  if (typeof cdrRaw === 'string' && cdrRaw.trim()) {
    try {
      const bytes = base64ToBytes(cdrRaw)
      result.cdr_path = await uploadBytes(
        admin,
        `${base}/R-${comp.serie}-${comp.correlativo}.zip`,
        bytes,
        'application/zip',
      )
    } catch (error) {
      console.error('No se pudo guardar el CDR del comprobante', error)
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

async function generatePdf(admin: SupabaseClient, comp: any, payload: any): Promise<string | null> {
  try {
    const response = await apiFetch('/invoice/pdf', {
      method: 'POST',
      body: JSON.stringify(payload),
    })

    if (!response.ok) return null

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
      `${documentBasePath(comp)}/${comp.serie}-${comp.correlativo}.pdf`,
      bytes,
      'application/pdf',
    )
  } catch (_) {
    return null
  }
}

async function generateXmlIfMissing(admin: SupabaseClient, comp: any, payload: any): Promise<string | null> {
  try {
    const response = await apiFetch('/invoice/xml', {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    if (!response.ok) return null
    const body = await responseBody(response)
    const raw = body?.xml || body?.data || body?.base64 || body?.raw
    if (typeof raw !== 'string' || !raw.trim()) return null
    const bytes = textOrBase64Bytes(raw)
    const ext = isZip(bytes) ? 'zip' : 'xml'
    return uploadBytes(
      admin,
      `${documentBasePath(comp)}/${comp.serie}-${comp.correlativo}.${ext}`,
      bytes,
      ext === 'zip' ? 'application/zip' : 'application/xml',
    )
  } catch (_) {
    return null
  }
}

async function fetchComprobante(admin: SupabaseClient, comprobanteId: string): Promise<any> {
  const { data, error } = await admin
    .from('comprobantes_electronicos')
    .select(`
      *,
      ventas!inner(
        id,
        total,
        saldo,
        estado,
        fecha,
        tipo_comprobante_solicitado,
        estado_facturacion,
        clientes(id,nombre,dni_ruc,direccion,tipo_doc),
        detalle_ventas(
          id,
          producto_id,
          cantidad,
          piezas_reales,
          precio_unitario,
          precio_unitario_comercial,
          subtotal,
          descuento_global_asignado,
          subtotal_final,
          almacen_id,
          tipo_unidad,
          tipo_venta_snapshot,
          pcs_snapshot,
          unidad_base_snapshot,
          presentation_snapshot,
          stock_scale_snapshot,
          productos(id,codigo,nombre,tipo_venta,cantidad_por_caja)
        )
      )
    `)
    .eq('id', comprobanteId)
    .single()

  if (error || !data) {
    throw new HttpError(404, 'Comprobante no encontrado', error?.message)
  }
  return data
}

function buildPayload(comp: any): any {
  const venta = comp.ventas
  if (!venta) throw new HttpError(409, 'La venta del comprobante no existe')

  if (asNumber(venta.saldo) > 0.01 || cleanText(venta.estado).toLowerCase() !== 'pagado') {
    throw new HttpError(409, 'La factura o boleta no está pagada completamente')
  }

  const tipo = cleanText(comp.tipo_documento_sunat).toLowerCase()
  const tipoDoc = tipo === 'factura' || tipo === '01'
    ? '01'
    : tipo === 'boleta' || tipo === '03'
    ? '03'
    : ''
  if (!tipoDoc) throw new HttpError(409, 'Tipo de comprobante electrónico inválido')

  const clientDoc = cleanText(comp.cliente_numero_documento, '0')
  const clientType = cleanText(comp.cliente_tipo_documento, clientDoc.length === 11 ? '6' : clientDoc.length === 8 ? '1' : '0')
  if (tipoDoc === '01' && (clientType !== '6' || !/^\d{11}$/.test(clientDoc))) {
    throw new HttpError(409, 'La factura requiere un cliente con RUC válido')
  }

  const detailsRaw = Array.isArray(venta.detalle_ventas) ? venta.detalle_ventas : []
  if (detailsRaw.length === 0) throw new HttpError(409, 'La venta no tiene detalles')

  const igvRate = 18
  const factor = 1 + (igvRate / 100)
  const targetBase = round(asNumber(comp.base_imponible), 2)
  const targetIgv = round(asNumber(comp.igv), 2)
  const targetTotal = round(asNumber(comp.total), 2)

  const details = detailsRaw.map((d: any) => {
    const product = d.productos || {}
    const configured = configuredFiscalPresentation(d, product)
    const quantity = configured?.quantity ?? asInt(d.cantidad)
    const fiscalUnitCode = configured?.unitCode ?? unitCode(d.tipo_unidad)
    const description = configured?.description ?? presentationDescription(d, product)
    const lineTotal = round(
      asNumber(d.subtotal_final, asNumber(d.subtotal)),
      2,
    )
    if (!Number.isFinite(quantity) || quantity <= 0 || lineTotal <= 0) {
      throw new HttpError(409, `Detalle inválido para ${cleanText(product.nombre, 'producto')}`)
    }

    const lineBase = round(lineTotal / factor, 2)
    const lineIgv = round(lineTotal - lineBase, 2)

    return {
      codProducto: cleanText(product.codigo, String(d.producto_id)),
      unidad: fiscalUnitCode,
      descripcion: description,
      cantidad: quantity,
      mtoValorUnitario: round(lineBase / quantity, 6),
      mtoValorVenta: lineBase,
      mtoBaseIgv: lineBase,
      porcentajeIgv: igvRate,
      igv: lineIgv,
      tipAfeIgv: 10,
      totalImpuestos: lineIgv,
      mtoPrecioUnitario: round(lineTotal / quantity, 6),
    }
  })

  const baseSum = round(details.reduce((sum: number, d: any) => sum + d.mtoValorVenta, 0), 2)
  const igvSum = round(details.reduce((sum: number, d: any) => sum + d.igv, 0), 2)
  const last = details[details.length - 1]
  if (last) {
    const baseDiff = round(targetBase - baseSum, 2)
    const igvDiff = round(targetIgv - igvSum, 2)
    last.mtoValorVenta = round(last.mtoValorVenta + baseDiff, 2)
    last.mtoBaseIgv = last.mtoValorVenta
    last.igv = round(last.igv + igvDiff, 2)
    last.totalImpuestos = last.igv
    last.mtoValorUnitario = round(last.mtoValorVenta / last.cantidad, 6)
    last.mtoPrecioUnitario = round((last.mtoValorVenta + last.igv) / last.cantidad, 6)
  }

  const client: Record<string, unknown> = {
    tipoDoc: clientType,
    numDoc: clientDoc,
    rznSocial: cleanText(comp.cliente_razon_social, 'CLIENTE GENERAL'),
  }
  const clientAddress = cleanText(comp.cliente_direccion)
  if (clientAddress && clientAddress.length > 2 && clientAddress !== '-') {
    client.address = { direccion: clientAddress }
  }

  const observationParts: string[] = []
  const discount = round(asNumber(comp.descuento_global_monto), 2)
  if (discount > 0) {
    observationParts.push(`DESCUENTO GLOBAL APLICADO: S/ ${discount.toFixed(2)}`)
  }

  return {
    ublVersion: '2.1',
    tipoOperacion: '0101',
    tipoDoc,
    serie: cleanText(comp.serie),
    correlativo: String(comp.correlativo),
    fechaEmision: formatLimaDateTime(comp.fecha_emision_ts || comp.fecha_emision),
    formaPago: {
      moneda: 'PEN',
      tipo: 'Contado',
    },
    tipoMoneda: 'PEN',
    client,
    company: {
      ruc: cleanText(comp.empresa_ruc),
      razonSocial: cleanText(comp.empresa_razon_social),
      nombreComercial: cleanText(comp.empresa_nombre_comercial, comp.empresa_razon_social),
      address: {
        direccion: cleanText(comp.empresa_direccion),
        provincia: cleanText(comp.empresa_provincia),
        departamento: cleanText(comp.empresa_departamento),
        distrito: cleanText(comp.empresa_distrito),
        ubigueo: cleanText(comp.empresa_ubigeo),
        codLocal: cleanText(comp.empresa_cod_local, '0000'),
      },
    },
    mtoOperGravadas: targetBase,
    mtoIGV: targetIgv,
    valorVenta: targetBase,
    totalImpuestos: targetIgv,
    subTotal: targetTotal,
    mtoImpVenta: targetTotal,
    details,
    legends: [
      { code: '1000', value: amountLegend(targetTotal) },
    ],
    ...(observationParts.length > 0
      ? { observacion: observationParts.join(' | ') }
      : {}),
    name: `${cleanText(comp.empresa_ruc)}-${tipoDoc}-${comp.serie}-${comp.correlativo}`,
  }
}

async function claim(
  context: FacturacionContext,
  comprobanteId: string,
  accion: string,
  forzar: boolean,
): Promise<any> {
  const { data, error } = await context.admin.rpc('facturacion_claim_comprobante', {
    p_comprobante_id: comprobanteId,
    p_usuario_id: context.user?.id ?? null,
    p_accion: accion,
    p_forzar: forzar,
    p_sistema: context.system,
  })
  if (error) throw new HttpError(409, error.message)
  return data
}

async function finalize(
  context: FacturacionContext,
  comprobanteId: string,
  bloqueoToken: string,
  estado: string,
  resultado: Record<string, unknown>,
): Promise<any> {
  const { data, error } = await context.admin.rpc('facturacion_finalizar_comprobante', {
    p_comprobante_id: comprobanteId,
    p_bloqueo_token: bloqueoToken,
    p_estado: estado,
    p_resultado: resultado,
  })
  if (error) throw new HttpError(500, error.message)
  return data
}

async function signedDocuments(admin: SupabaseClient, comp: any): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  for (const [key, path] of Object.entries({
    pdf: comp.pdf_path,
    xml: comp.xml_path,
    cdr: comp.cdr_path,
  })) {
    if (typeof path !== 'string' || !path.trim()) continue
    const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(path, 3600)
    if (!error && data?.signedUrl) result[key] = data.signedUrl
  }
  return result
}

function publicComprobante(comp: any, documents: Record<string, string>): any {
  return {
    id: comp.id,
    venta_id: comp.venta_id,
    tipo_documento_sunat: comp.tipo_documento_sunat,
    serie: comp.serie,
    correlativo: comp.correlativo,
    fecha_emision: comp.fecha_emision,
    estado: comp.estado,
    codigo_sunat: comp.codigo_sunat,
    descripcion_sunat: comp.descripcion_sunat,
    observaciones_sunat: comp.observaciones_sunat,
    numero_reintentos: comp.numero_reintentos,
    ultimo_error_tipo: comp.ultimo_error_tipo,
    ultimo_http_status: comp.ultimo_http_status,
    ultimo_intento_at: comp.ultimo_intento_at,
    aceptado_at: comp.aceptado_at,
    total: comp.total,
    estado_baja_tributaria: comp.estado_baja_tributaria,
    solicitud_baja_id: comp.solicitud_baja_id,
    baja_motivo: comp.baja_motivo,
    baja_aceptada_at: comp.baja_aceptada_at,
    documentos: documents,
  }
}

export async function emitirComprobanteCore(options: EmitOptions): Promise<any> {
  const started = Date.now()

  // SUNAT permite enviar la factura y su nota vinculada hasta tres días
  // calendario posteriores a la fecha de emisión. No se permite que un
  // reintento manual convierta un documento antiguo en un nuevo envío.
  const preflight = await fetchComprobante(
    options.context.admin,
    options.comprobanteId,
  )

  if (cleanText(preflight.ticket_sunat)) {
    return consultarComprobanteCore({
      comprobanteId: options.comprobanteId,
      consultarSunat: true,
      context: options.context,
    })
  }
  const preflightType = cleanText(
    preflight.tipo_documento_sunat,
  ).toLowerCase()
  if (
    (preflightType === 'factura' || preflightType === '01') &&
    sunatSendDeadlineExpired(
      preflight.fecha_emision_ts || preflight.fecha_emision,
    )
  ) {
    const message =
      'El plazo máximo de envío de esta factura ya venció. No se realizó un nuevo envío. Consulta primero su estado en SUNAT y resuelve el documento manualmente.'
    return {
      success: false,
      estado: preflight.estado,
      bloqueado_por_plazo: true,
      mensaje: message,
      comprobante: publicComprobante(
        preflight,
        await signedDocuments(options.context.admin, preflight),
      ),
    }
  }

  const claimData = await claim(
    options.context,
    options.comprobanteId,
    options.accion,
    Boolean(options.forzar),
  )

  if (claimData?.claimed !== true) {
    const current = await fetchComprobante(options.context.admin, options.comprobanteId)
    return {
      success: current.estado === 'aceptado',
      estado: current.estado,
      mensaje: claimData?.mensaje,
      comprobante: publicComprobante(current, await signedDocuments(options.context.admin, current)),
    }
  }

  const bloqueoToken = String(claimData.bloqueo_token)
  const intentoId = String(claimData.intento_id)
  let payload: any = null
  let remoteRequestStarted = false

  try {
    const comp = await fetchComprobante(options.context.admin, options.comprobanteId)
    payload = buildPayload(comp)

    await options.context.admin
      .from('facturacion_intentos')
      .update({ payload_json: payload })
      .eq('id', intentoId)

    await options.context.admin
      .from('comprobantes_electronicos')
      .update({
        payload_json: payload,
        archivo_nombre_base: payload.name,
      })
      .eq('id', options.comprobanteId)

    remoteRequestStarted = true
    const response = await apiFetch('/invoice/send', {
      method: 'POST',
      body: JSON.stringify(payload),
    })
    const body = await responseBody(response)
    const docs = await saveApiDocuments(options.context.admin, comp, body)

    if (response.ok && isAccepted(body)) {
      const pdfPath = await generatePdf(options.context.admin, comp, payload)
      const result = await finalize(
        options.context,
        options.comprobanteId,
        bloqueoToken,
        'aceptado',
        {
          intento_id: intentoId,
          codigo_http: response.status,
          duracion_ms: Date.now() - started,
          payload_json: payload,
          respuesta_json: body,
          ...docs,
          ...(pdfPath ? { pdf_path: pdfPath } : {}),
          hash_documento: cleanText(body?.hash),
          codigo_sunat: responseCode(body) || '0',
          descripcion_sunat: responseMessage(body, 'Aceptado por SUNAT'),
          observaciones_sunat: responseNotes(body),
          ticket_sunat: cleanText(body?.sunatResponse?.ticket),
          archivo_nombre_base: payload.name,
        },
      )
      const current = await fetchComprobante(options.context.admin, options.comprobanteId)
      return {
        ...result,
        comprobante: publicComprobante(current, await signedDocuments(options.context.admin, current)),
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
        ? 'No se recibió un CDR final. No reenvíes el comprobante hasta consultar su estado o completar la reconciliación administrativa.'
        : state === 'pendiente_reintento'
        ? definitiveValidation
          ? 'El proveedor detectó errores de validación antes de obtener un CDR. Corrige los datos y vuelve a intentarlo.'
          : 'El proveedor rechazó la autenticación o limitó la solicitud antes de enviarla a SUNAT. Corrige la configuración y reintenta.'
        : 'El comprobante fue rechazado por un CDR definitivo de SUNAT.',
    )

    await finalize(
      options.context,
      options.comprobanteId,
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
        remoto_iniciado: remoteRequestStarted,
        archivo_nombre_base: payload.name,
      },
    )

    const current = await fetchComprobante(options.context.admin, options.comprobanteId)
    return {
      success: false,
      estado: state,
      mensaje: message,
      comprobante: publicComprobante(current, await signedDocuments(options.context.admin, current)),
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const state = remoteRequestStarted
      ? 'resultado_incierto'
      : 'pendiente_reintento'
    const description = remoteRequestStarted
      ? 'No se recibió el resultado final del envío. No reenvíes el comprobante hasta consultar SUNAT o completar la reconciliación.'
      : 'El comprobante no llegó a enviarse al proveedor. Corrige el problema y vuelve a intentarlo.'

    await finalize(
      options.context,
      options.comprobanteId,
      bloqueoToken,
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
        remoto_iniciado: remoteRequestStarted,
      },
    )

    const current = await fetchComprobante(
      options.context.admin,
      options.comprobanteId,
    )
    return {
      success: false,
      estado: state,
      mensaje: description,
      comprobante: publicComprobante(
        current,
        await signedDocuments(options.context.admin, current),
      ),
    }
  }
}

async function ensureAcceptedDocuments(context: FacturacionContext, comp: any): Promise<any> {
  const payload = comp.payload_json || buildPayload(comp)
  const updates: Record<string, unknown> = {}

  if (!comp.xml_path) {
    const xmlPath = await generateXmlIfMissing(context.admin, comp, payload)
    if (xmlPath) updates.xml_path = xmlPath
  }
  if (!comp.pdf_path) {
    const pdfPath = await generatePdf(context.admin, comp, payload)
    if (pdfPath) {
      updates.pdf_path = pdfPath
      updates.pdf_generado_at = new Date().toISOString()
    }
  }

  if (Object.keys(updates).length > 0) {
    await context.admin
      .from('comprobantes_electronicos')
      .update(updates)
      .eq('id', comp.id)
    return fetchComprobante(context.admin, comp.id)
  }
  return comp
}

export async function consultarComprobanteCore(options: ConsultOptions): Promise<any> {
  let comp = await fetchComprobante(options.context.admin, options.comprobanteId)

  const estadosConsultablesRemotos = new Set([
    'pendiente_reintento',
    'procesando',
    'ticket_pendiente',
    'resultado_incierto',
    'rechazado',
  ])

  if (options.consultarSunat && estadosConsultablesRemotos.has(comp.estado)) {
    const previousState = cleanText(comp.estado, 'pendiente_reintento').toLowerCase()
    const claimData = await claim(options.context, options.comprobanteId, 'consultar', false)
    if (claimData?.claimed === true) {
      const started = Date.now()
      const bloqueoToken = String(claimData.bloqueo_token)
      const intentoId = String(claimData.intento_id)
      const stateToPreserve = previousState === 'procesando'
        ? 'resultado_incierto'
        : previousState

      try {
        const rawTipo = cleanText(comp.tipo_documento_sunat).toLowerCase()
        const tipo = rawTipo === 'factura' || rawTipo === '01' ? '01' : '03'
        const params = new URLSearchParams({
          tipo,
          serie: String(comp.serie),
          numero: String(comp.correlativo),
          ruc: String(comp.empresa_ruc),
        })
        const response = await apiFetch(`/invoice/status?${params.toString()}`, {
          method: 'GET',
          headers: {},
        })
        const body = await responseBody(response)
        const docs = await saveApiDocuments(options.context.admin, comp, body)

        if (response.ok && isAccepted(body)) {
          const payload = comp.payload_json || buildPayload(comp)
          const pdfPath = comp.pdf_path || await generatePdf(options.context.admin, comp, payload)
          const xmlPath = comp.xml_path || await generateXmlIfMissing(options.context.admin, comp, payload)
          await finalize(
            options.context,
            options.comprobanteId,
            bloqueoToken,
            'aceptado',
            {
              intento_id: intentoId,
              codigo_http: response.status,
              duracion_ms: Date.now() - started,
              respuesta_json: body,
              ...docs,
              ...(pdfPath ? { pdf_path: pdfPath } : {}),
              ...(xmlPath ? { xml_path: xmlPath } : {}),
              codigo_sunat: responseCode(body) || '0',
              descripcion_sunat: responseMessage(body, 'Aceptado por SUNAT'),
              observaciones_sunat: responseNotes(body),
              fue_consulta: true,
              estado_anterior: previousState,
            },
          )
        } else if (isFinalRejected(body)) {
          const message = responseMessage(body, 'Comprobante rechazado por SUNAT')
          await finalize(
            options.context,
            options.comprobanteId,
            bloqueoToken,
            'rechazado',
            {
              intento_id: intentoId,
              codigo_http: response.status,
              duracion_ms: Date.now() - started,
              respuesta_json: body,
              ...docs,
              codigo_error: responseCode(body),
              mensaje_error: message,
              descripcion_sunat: message,
              observaciones_sunat: responseNotes(body),
              error_tipo: 'sunat',
              fue_consulta: true,
              estado_anterior: previousState,
            },
          )
        } else {
          const preserve = [
            'pendiente',
            'pendiente_envio',
            'pendiente_reintento',
            'resultado_incierto',
            'ticket_pendiente',
            'rechazado',
          ].includes(stateToPreserve)
            ? stateToPreserve
            : 'resultado_incierto'
          const message = responseMessage(
            body,
            preserve === 'resultado_incierto'
              ? 'SUNAT todavía no devuelve un resultado definitivo. El comprobante continúa con resultado incierto.'
              : 'La consulta no devolvió un CDR definitivo; se conserva el estado anterior.',
          )
          await finalize(
            options.context,
            options.comprobanteId,
            bloqueoToken,
            preserve,
            {
              intento_id: intentoId,
              codigo_http: response.status,
              duracion_ms: Date.now() - started,
              respuesta_json: body,
              ...docs,
              codigo_error: responseCode(body),
              mensaje_error: message,
              descripcion_sunat: message,
              error_tipo: 'consulta_sin_resultado_final',
              fue_consulta: true,
              estado_anterior: previousState,
            },
          )
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        const preserve = [
          'pendiente',
          'pendiente_envio',
          'pendiente_reintento',
          'resultado_incierto',
          'ticket_pendiente',
          'rechazado',
        ].includes(stateToPreserve)
          ? stateToPreserve
          : 'resultado_incierto'
        await finalize(
          options.context,
          options.comprobanteId,
          bloqueoToken,
          preserve,
          {
            intento_id: intentoId,
            duracion_ms: Date.now() - started,
            mensaje_error: message,
            descripcion_sunat: preserve === 'resultado_incierto'
              ? 'No se pudo completar la consulta. El comprobante conserva el resultado incierto y no debe reenviarse.'
              : 'No se pudo completar la consulta. Se conserva el estado anterior.',
            error_tipo: 'conexion_consulta',
            fue_consulta: true,
            estado_anterior: previousState,
          },
        )
      }
      comp = await fetchComprobante(options.context.admin, options.comprobanteId)
    }
  }

  if (comp.estado === 'aceptado') {
    comp = await ensureAcceptedDocuments(options.context, comp)
  }

  return {
    success: true,
    estado: comp.estado,
    comprobante: publicComprobante(comp, await signedDocuments(options.context.admin, comp)),
  }
}
