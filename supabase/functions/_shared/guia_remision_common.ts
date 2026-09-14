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
const SEND_TIMEOUT_MS = 75_000
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

export type GreContext = {
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

function apiEnvironment(): 'beta' | 'produccion' {
  const raw = cleanText(Deno.env.get('APIS_PERU_ENVIRONMENT')).toLowerCase()
  if (['beta', 'demo', 'pruebas', 'nubefact_beta'].includes(raw)) {
    return 'beta'
  }
  if (['produccion', 'production', 'prod'].includes(raw)) {
    return 'produccion'
  }
  throw new HttpError(
    500,
    'APIS_PERU_ENVIRONMENT debe ser beta o produccion.',
  )
}

export async function createUserContext(
  req: Request,
  allowedRoles: readonly AppRole[] = ['admin', 'operador'],
): Promise<GreContext> {
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
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function ceilToMinute(value: Date): Date {
  const time = value.getTime()
  const minute = 60_000
  return new Date(Math.ceil(time / minute) * minute)
}

function minimumRetryTransferStart(now = new Date()): Date {
  return ceilToMinute(new Date(now.getTime() + 60_000))
}

function formatLimaForUser(value: Date): string {
  return new Intl.DateTimeFormat('es-PE', {
    timeZone: 'America/Lima',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(value)
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

function responseMessage(body: any, fallback: string): string {
  const rawError = body?.sunatResponse?.error ?? body?.error
  const errorMessage = typeof rawError === 'string'
    ? rawError
    : rawError?.message

  return cleanText(
    body?.cdrResponse?.description ||
    body?.sunatResponse?.cdrResponse?.description ||
    errorMessage ||
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
    body?.cdrResponse?.notes ||
    body?.sunatResponse?.cdrResponse?.notes
  return Array.isArray(notes) ? notes : []
}

function cdrResponse(body: any): any {
  return body?.cdrResponse || body?.sunatResponse?.cdrResponse
}

function acceptedByCdr(body: any): boolean {
  const cdr = cdrResponse(body)
  if (!cdr) return false
  if (cdr.accepted === true) return true
  if (cdr.accepted === false) return false

  const success =
    body?.success === true || body?.sunatResponse?.success === true
  return success && cleanText(cdr.code) === '0'
}

function rejectedByCdr(body: any): boolean {
  const cdr = cdrResponse(body)
  if (!cdr) return false
  if (cdr.accepted === false) return true
  const code = cleanText(cdr.code)
  return code !== '' && code !== '0'
}

async function fetchJson(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<{ status: number; body: any }> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const response = await fetch(url, {
      ...init,
      signal: controller.signal,
    })

    const text = await response.text()
    let body: any = {}
    if (text.trim()) {
      try {
        body = JSON.parse(text)
      } catch {
        body = { raw: text }
      }
    }

    return { status: response.status, body }
  } finally {
    clearTimeout(timeout)
  }
}

function base64Bytes(value: string): Uint8Array {
  const normalized = value.includes(',')
    ? value.substring(value.indexOf(',') + 1)
    : value
  const binary = atob(normalized)
  return Uint8Array.from(binary, (char) => char.charCodeAt(0))
}

function textBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value)
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
  })
  if (error) throw new HttpError(500, `No se pudo guardar ${path}`, error)
  return path
}

function storageBasePath(guia: any, company: any): string {
  const year = new Date(guia.fecha_emision || guia.created_at || Date.now())
    .getUTCFullYear()
  const number = `${guia.serie}-${guia.correlativo}`
  return `${company.ruc}/${year}/guia_remision/${number}`
}

async function saveXml(
  admin: SupabaseClient,
  guia: any,
  company: any,
  body: any,
): Promise<string | null> {
  const xml = cleanText(body?.xml || body?.data?.xml || body?.data || body?.raw)
  if (!xml) return guia.xml_path || null
  const name = `${guia.serie}-${guia.correlativo}.xml`
  try {
    const bytes = xml.startsWith('<') || xml.startsWith('<?xml')
      ? textBytes(xml)
      : base64Bytes(xml)
    return await uploadBytes(
      admin,
      `${storageBasePath(guia, company)}/${name}`,
      bytes,
      'application/xml',
    )
  } catch (error) {
    console.error('No se pudo guardar el XML de la GRE', error)
    return guia.xml_path || null
  }
}

async function saveCdr(
  admin: SupabaseClient,
  guia: any,
  company: any,
  body: any,
): Promise<string | null> {
  const cdr = cleanText(body?.cdrZip || body?.sunatResponse?.cdrZip)
  if (!cdr) return guia.cdr_path || null
  const name = `R-${guia.serie}-${guia.correlativo}.zip`
  try {
    return await uploadBytes(
      admin,
      `${storageBasePath(guia, company)}/${name}`,
      base64Bytes(cdr),
      'application/zip',
    )
  } catch (error) {
    console.error('No se pudo guardar el CDR de la GRE', error)
    return guia.cdr_path || null
  }
}

async function generatePdf(
  admin: SupabaseClient,
  guia: any,
  company: any,
  payload: any,
): Promise<string | null> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), SEND_TIMEOUT_MS)

  try {
    const response = await fetch(`${apiBaseUrl()}/despatch/pdf`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${requiredEnv('APIS_PERU_TOKEN')}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    })

    if (!response.ok) return guia.pdf_path || null

    const contentType = (response.headers.get('content-type') || '').toLowerCase()
    const rawBytes = new Uint8Array(await response.arrayBuffer())
    let pdfBytes: Uint8Array | null = null

    const hasPdfSignature =
      rawBytes.length >= 4 &&
      rawBytes[0] === 0x25 && // %
      rawBytes[1] === 0x50 && // P
      rawBytes[2] === 0x44 && // D
      rawBytes[3] === 0x46    // F

    if (
      contentType.includes('application/pdf') ||
      contentType.includes('application/octet-stream') ||
      hasPdfSignature
    ) {
      pdfBytes = rawBytes
    } else {
      const text = new TextDecoder().decode(rawBytes).trim()
      if (text) {
        try {
          const body = JSON.parse(text)
          const candidate = cleanText(
            body?.pdf || body?.pdfBase64 || body?.base64 || body?.data,
          )
          if (candidate) pdfBytes = base64Bytes(candidate)
        } catch {
          // Una respuesta no JSON y sin firma PDF no se guarda como archivo.
        }
      }
    }

    if (!pdfBytes || pdfBytes.length === 0) {
      return guia.pdf_path || null
    }

    const name = `${guia.serie}-${guia.correlativo}.pdf`
    return uploadBytes(
      admin,
      `${storageBasePath(guia, company)}/${name}`,
      pdfBytes,
      'application/pdf',
    )
  } catch {
    return guia.pdf_path || null
  } finally {
    clearTimeout(timeout)
  }
}

function clientObject(
  tipoDoc: unknown,
  numDoc: unknown,
  rznSocial: unknown,
): Record<string, unknown> {
  return {
    tipoDoc: cleanText(tipoDoc, '6'),
    numDoc: cleanText(numDoc),
    rznSocial: cleanText(rznSocial),
  }
}

function groupedDetails(details: any[]): any[] {
  const grouped = new Map<string, any>()

  for (const detail of details) {
    const cantidad = asNumber(detail.cantidad)
    if (cantidad <= 0) continue

    const unidad = cleanText(detail.unidad, 'NIU').toUpperCase()
    const descripcion = cleanText(detail.descripcion)
    const codigo = cleanText(detail.codigo, `ITEM-${detail.id}`)
    const key = `${codigo}|${unidad}|${descripcion}`

    const current = grouped.get(key)
    if (current) {
      current.cantidad += cantidad
    } else {
      grouped.set(key, {
        cantidad,
        unidad,
        descripcion,
        codigo,
      })
    }
  }

  return [...grouped.values()]
}

function buildPayload(guia: any, company: any, details: any[]): any {
  const envio: any = {
    codTraslado: cleanText(guia.motivo_codigo),
    desTraslado: cleanText(guia.motivo_descripcion),
    modTraslado: cleanText(guia.modalidad_transporte),
    fecTraslado: formatLimaDateTime(guia.fecha_traslado),
    fecEntregaBienes: formatLimaDateTime(guia.fecha_traslado),
    indTransbordo: guia.ind_transbordo === true,
    pesoTotal: asNumber(guia.peso_total),
    undPesoTotal: cleanText(guia.unidad_peso, 'KGM'),
    llegada: {
      ubigueo: cleanText(guia.llegada_ubigeo),
      direccion: cleanText(guia.llegada_direccion),
    },
    partida: {
      ubigueo: cleanText(guia.partida_ubigeo),
      direccion: cleanText(guia.partida_direccion),
    },
  }

  const cantidadBultos = asNumber(guia.cantidad_bultos)
  if (Number.isInteger(cantidadBultos) && cantidadBultos > 0) {
    envio.numBultos = cantidadBultos
  }

  const esPublico = cleanText(guia.modalidad_transporte) === '01'
  const esTransportista = cleanText(guia.tipo_documento_sunat) === '31'

  if (esPublico && !esTransportista) {
    const nroMtc = cleanText(
      guia.transportista_registro_mtc_snapshot,
    )

    envio.transportista = {
      tipoDoc: '6',
      numDoc: cleanText(guia.transportista_ruc_snapshot),
      rznSocial: cleanText(
        guia.transportista_razon_social_snapshot,
      ),
      ...(nroMtc ? { nroMtc } : {}),
    }
  } else {
    envio.vehiculo = {
      placa: cleanText(guia.vehiculo_placa_snapshot),
      nroCirculacion: cleanText(
        guia.vehiculo_constancia_snapshot,
      ),
      marca: cleanText(guia.vehiculo_marca_snapshot),
    }

    envio.choferes = [
      {
        tipo: 'Principal',
        tipoDoc: cleanText(
          guia.conductor_tipo_documento_snapshot,
          '1',
        ),
        nroDoc: cleanText(guia.conductor_documento_snapshot),
        licencia: cleanText(guia.conductor_licencia_snapshot),
        nombres: cleanText(guia.conductor_nombres_snapshot),
        apellidos: cleanText(
          guia.conductor_apellidos_snapshot,
        ),
      },
    ]

    if (esTransportista) {
      envio.transportista = {
        tipoDoc: '6',
        numDoc: cleanText(company.ruc),
        rznSocial: cleanText(company.razon_social),
        nroMtc: cleanText(
          guia.transportista_registro_mtc_snapshot,
        ),
      }
    }
  }

  const payload: any = {
    version: '2022',
    tipoDoc: guia.tipo_documento_sunat,
    serie: guia.serie,
    correlativo: String(guia.correlativo),
    fechaEmision: formatLimaDateTime(guia.fecha_emision),
    observacion: cleanText(guia.observacion),
    company: {
      ruc: cleanText(company.ruc),
      razonSocial: cleanText(company.razon_social),
      nombreComercial: cleanText(
        company.nombre_comercial,
        company.razon_social,
      ),
      address: {
        direccion: cleanText(company.direccion),
        provincia: cleanText(company.provincia),
        departamento: cleanText(company.departamento),
        distrito: cleanText(company.distrito),
        ubigueo: cleanText(company.ubigeo),
      },
    },
    destinatario: clientObject(
      guia.destinatario_tipo_documento,
      guia.destinatario_numero_documento,
      guia.destinatario_razon_social,
    ),
    envio,
    details: groupedDetails(details),
    name: `${guia.serie}-${guia.correlativo}`,
  }

  if (guia.tipo_documento_sunat === '31') {
    payload.remitente = clientObject(
      guia.remitente_tipo_documento,
      guia.remitente_numero_documento,
      guia.remitente_razon_social,
    )
  }

  if (
    cleanText(guia.documento_relacionado_tipo) &&
    cleanText(guia.documento_relacionado_numero)
  ) {
    payload.relDoc = {
      tipoDoc: cleanText(guia.documento_relacionado_tipo),
      nroDoc: cleanText(guia.documento_relacionado_numero),
    }
  }

  return payload
}

function validatePayloadBeforeSend(payload: any): string[] {
  const errors: string[] = []
  const envio = payload?.envio || {}
  const isPublic = cleanText(envio?.modTraslado) === '01'
  const isCarrierGuide = cleanText(payload?.tipoDoc) === '31'
  const isProgrammedTransfer = envio?.indTransbordo === true

  if (isProgrammedTransfer && (isPublic || isCarrierGuide)) {
    errors.push(
      'El transbordo programado de esta app requiere GRE Remitente con primer tramo privado.',
    )
  }

  if (!cleanText(payload?.serie) || !cleanText(payload?.correlativo)) {
    errors.push('La guía todavía no tiene serie o correlativo.')
  }

  if (cleanText(envio?.partida?.direccion).length < 5) {
    errors.push('La dirección de partida está incompleta.')
  }

  if (!/^[0-9]{6}$/.test(cleanText(envio?.partida?.ubigueo))) {
    errors.push('El ubigeo de partida es inválido.')
  }

  if (cleanText(envio?.llegada?.direccion).length < 5) {
    errors.push('La dirección de llegada está incompleta.')
  }

  if (!/^[0-9]{6}$/.test(cleanText(envio?.llegada?.ubigueo))) {
    errors.push('El ubigeo de llegada es inválido.')
  }

  if (asNumber(envio?.pesoTotal) <= 0) {
    errors.push('El peso total debe ser mayor a cero.')
  }

  if (!Array.isArray(payload?.details) || payload.details.length === 0) {
    errors.push('La guía no contiene productos.')
  }

  if (isPublic && !isCarrierGuide) {
    if (
      !cleanText(envio?.transportista?.numDoc) ||
      !cleanText(envio?.transportista?.rznSocial)
    ) {
      errors.push(
        'En transporte público falta la empresa transportista.',
      )
    }
  } else {
    const driver = Array.isArray(envio?.choferes)
      ? envio.choferes[0]
      : null

    if (!cleanText(envio?.vehiculo?.placa)) {
      errors.push('Falta la placa del vehículo.')
    }

    if (!cleanText(envio?.vehiculo?.nroCirculacion)) {
      errors.push(
        'Falta la constancia de inscripción o habilitación vehicular.',
      )
    }

    if (!cleanText(envio?.vehiculo?.marca)) {
      errors.push('Falta la marca del vehículo.')
    }

    if (!cleanText(driver?.nroDoc)) {
      errors.push('Falta el documento del conductor.')
    }

    if (!cleanText(driver?.licencia)) {
      errors.push('Falta la licencia del conductor.')
    }

    if (
      !cleanText(driver?.nombres) ||
      !cleanText(driver?.apellidos)
    ) {
      errors.push('Faltan nombres o apellidos del conductor.')
    }
  }

  return errors
}

async function loadGuide(
  admin: SupabaseClient,
  guiaId: string,
): Promise<{ guia: any; company: any; details: any[] }> {
  const [guideResult, companyResult, detailsResult] = await Promise.all([
    admin.from('guias_remision').select('*').eq('id', guiaId).single(),
    admin.from('configuracion_negocio').select('*').order('id').limit(1).single(),
    admin
      .from('guias_remision_detalles')
      .select('*')
      .eq('guia_id', guiaId)
      .order('id'),
  ])

  if (guideResult.error) {
    throw new HttpError(404, 'Guía no encontrada', guideResult.error)
  }
  if (companyResult.error) {
    throw new HttpError(
      500,
      'Configuración de empresa incompleta',
      companyResult.error,
    )
  }
  if (detailsResult.error) {
    throw new HttpError(500, 'No se pudieron cargar los productos')
  }

  return {
    guia: guideResult.data,
    company: companyResult.data,
    details: detailsResult.data || [],
  }
}

async function claim(
  context: GreContext,
  guiaId: string,
  accion: string,
  forzar = false,
): Promise<any> {
  const { data, error } = await context.admin.rpc('gre_claim_v2', {
    p_guia_id: guiaId,
    p_usuario_id: context.user?.id ?? null,
    p_accion: accion,
    p_forzar: forzar,
    p_sistema: context.system,
  })
  if (error) throw new HttpError(400, error.message, error)
  return data
}

async function finalize(
  context: GreContext,
  guiaId: string,
  bloqueoToken: string,
  estado: string,
  result: Record<string, unknown>,
): Promise<any> {
  const { data, error } = await context.admin.rpc('gre_finalizar', {
    p_guia_id: guiaId,
    p_bloqueo_token: bloqueoToken,
    p_estado: estado,
    p_resultado: result,
  })
  if (error) throw new HttpError(400, error.message, error)
  return data
}

async function signedDocuments(
  admin: SupabaseClient,
  guia: any,
): Promise<Record<string, string | null>> {
  const sign = async (path: unknown): Promise<string | null> => {
    const value = cleanText(path)
    if (!value) return null
    const { data, error } = await admin.storage
      .from(BUCKET)
      .createSignedUrl(value, 3600)
    return error ? null : data.signedUrl
  }

  const [pdf, xml, cdr] = await Promise.all([
    sign(guia.pdf_path),
    sign(guia.xml_path),
    sign(guia.cdr_path),
  ])

  return { pdf, xml, cdr }
}

async function localResponse(
  context: GreContext,
  guiaId: string,
): Promise<any> {
  const loaded = await loadGuide(context.admin, guiaId)
  return {
    success: ['aceptado', 'xml_validado_prueba'].includes(
      cleanText(loaded.guia.estado).toLowerCase(),
    ),
    estado: loaded.guia.estado,
    guia: {
      ...loaded.guia,
      detalles: loaded.details,
      documentos: await signedDocuments(context.admin, loaded.guia),
    },
  }
}

async function consultTicket(
  context: GreContext,
  guiaId: string,
  accion = 'consultar',
): Promise<any> {
  const loaded = await loadGuide(context.admin, guiaId)
  const current = loaded.guia
  const ticket = cleanText(current.ticket_sunat)

  if (!ticket) return localResponse(context, guiaId)

  const claimData = await claim(context, guiaId, accion, false)
  if (claimData?.claimed !== true) {
    return localResponse(context, guiaId)
  }

  const start = Date.now()
  const bloqueoToken = String(claimData.bloqueo_token)
  const intentoId = String(claimData.intento_id)

  try {
    const query = new URLSearchParams({
      ticket,
      ruc: cleanText(loaded.company.ruc),
    })

    const result = await fetchJson(
      `${apiBaseUrl()}/despatch/status?${query.toString()}`,
      {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${requiredEnv('APIS_PERU_TOKEN')}`,
          Accept: 'application/json',
        },
      },
      STATUS_TIMEOUT_MS,
    )

    const cdrPath = await saveCdr(
      context.admin,
      current,
      loaded.company,
      result.body,
    )

    if (acceptedByCdr(result.body)) {
      const payload = current.payload_json ||
        buildPayload(current, loaded.company, loaded.details)
      const pdfPath = current.pdf_path ||
        await generatePdf(context.admin, current, loaded.company, payload)

      await finalize(context, guiaId, bloqueoToken, 'aceptado', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        respuesta_json: result.body,
        codigo_sunat: responseCode(result.body) || '0',
        descripcion_sunat: responseMessage(
          result.body,
          'Guía aceptada por SUNAT',
        ),
        observaciones_sunat: responseNotes(result.body),
        cdr_path: cdrPath,
        pdf_path: pdfPath,
        fue_consulta: true,
      })
    } else if (rejectedByCdr(result.body)) {
      await finalize(context, guiaId, bloqueoToken, 'pendiente_reintento', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        respuesta_json: result.body,
        codigo_sunat: responseCode(result.body),
        descripcion_sunat: responseMessage(
          result.body,
          'La guía fue rechazada por SUNAT',
        ),
        observaciones_sunat: responseNotes(result.body),
        cdr_path: cdrPath,
        fue_consulta: true,
      })
    } else {
      await finalize(context, guiaId, bloqueoToken, 'ticket_pendiente', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        respuesta_json: result.body,
        descripcion_sunat:
          'Ticket recibido. SUNAT todavía no devuelve el CDR.',
        ticket_sunat: ticket,
        error_tipo: result.status >= 500 ? 'conexion' : 'pendiente',
        fue_consulta: true,
      })
    }
  } catch (error) {
    await finalize(context, guiaId, bloqueoToken, 'ticket_pendiente', {
      intento_id: intentoId,
      duracion_ms: Date.now() - start,
      ticket_sunat: ticket,
      mensaje_error:
        error instanceof Error ? error.message : String(error),
      descripcion_sunat:
        'Ticket conservado. La consulta se intentará nuevamente sin reenviar.',
      error_tipo: 'conexion',
      fue_consulta: true,
    })
  }

  return localResponse(context, guiaId)
}

export async function emitirGuiaCore(
  context: GreContext,
  guiaId: string,
  accion: 'emitir' | 'reintentar' = 'emitir',
  forzar = false,
): Promise<any> {
  const before = await loadGuide(context.admin, guiaId)
  const environment = apiEnvironment()
  const isBeta = environment === 'beta'

  const ambienteAnterior = cleanText(before.guia.ambiente_emision).toLowerCase()
  const fuePrueba = before.guia.es_prueba === true || ambienteAnterior === 'beta'

  if (!isBeta && fuePrueba) {
    throw new HttpError(
      409,
      'Esta GRE pertenece al flujo de pruebas beta. Crea una nueva guía para producción; no reutilices serie, correlativo ni datos de prueba.',
    )
  }

  if (isBeta && ambienteAnterior === 'produccion') {
    throw new HttpError(
      409,
      'Esta GRE pertenece a producción. Cambia el backend a producción para consultar su ticket o CDR; no la proceses en beta.',
    )
  }

  if (cleanText(before.guia.ticket_sunat)) {
    return consultTicket(context, guiaId, 'consultar')
  }

  if (before.guia.estado === 'resultado_incierto') {
    return {
      ...(await localResponse(context, guiaId)),
      success: false,
      mensaje:
        'No se confirmó si SUNAT recibió la GRE. Un administrador debe reconciliarla antes de habilitar otro envío.',
    }
  }

  // Para reintentos productivos la fecha de traslado debe seguir siendo futura.
  if (!isBeta && accion === 'reintentar') {
    const fechaTraslado = new Date(String(before.guia.fecha_traslado || ''))
    const inicioMinimo = minimumRetryTransferStart()

    if (
      Number.isNaN(fechaTraslado.getTime()) ||
      fechaTraslado.getTime() < inicioMinimo.getTime()
    ) {
      throw new HttpError(
        409,
        `El inicio del traslado ya venció. Corrige la guía y selecciona ` +
        `una fecha y hora futura, como mínimo ${formatLimaForUser(inicioMinimo)}.`,
        {
          code: 'TRASLADO_VENCIDO',
          inicio_minimo: inicioMinimo.toISOString(),
        },
      )
    }
  }

  const claimData = await claim(context, guiaId, accion, forzar)
  if (claimData?.claimed !== true) {
    if (cleanText(claimData?.codigo) === 'TRASLADO_VENCIDO') {
      throw new HttpError(
        409,
        cleanText(
          claimData?.mensaje,
          'El inicio del traslado ya venció. Corrige la guía antes de reintentar.',
        ),
        { code: 'TRASLADO_VENCIDO' },
      )
    }
    return localResponse(context, guiaId)
  }

  const start = Date.now()
  const bloqueoToken = String(claimData.bloqueo_token)
  const intentoId = String(claimData.intento_id)
  let payload: any = null
  let remoteRequestStarted = false

  try {
    const loaded = await loadGuide(context.admin, guiaId)
    payload = buildPayload(loaded.guia, loaded.company, loaded.details)

    const validationErrors = validatePayloadBeforeSend(payload)
    if (validationErrors.length > 0) {
      await finalize(context, guiaId, bloqueoToken, 'pendiente_reintento', {
        intento_id: intentoId,
        codigo_http: 422,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: {
          success: false,
          error: validationErrors.join(' '),
          source: 'validacion_local',
        },
        mensaje_error: validationErrors.join(' '),
        descripcion_sunat: validationErrors.join(' '),
        error_tipo: 'validacion_local',
        ambiente_emision: environment,
        es_prueba: isBeta,
      })
      return localResponse(context, guiaId)
    }

    await context.admin
      .from('guias_remision')
      .update({
        payload_json: payload,
        ambiente_emision: environment,
        es_prueba: isBeta,
      })
      .eq('id', guiaId)

    if (isBeta) {
      const result = await fetchJson(
        `${apiBaseUrl()}/despatch/xml`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${requiredEnv('APIS_PERU_TOKEN')}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(payload),
        },
        SEND_TIMEOUT_MS,
      )

      const xmlPath = await saveXml(
        context.admin,
        loaded.guia,
        loaded.company,
        result.body,
      )

      if (result.status >= 200 && result.status < 300 && xmlPath) {
        await finalize(context, guiaId, bloqueoToken, 'xml_validado_prueba', {
          intento_id: intentoId,
          codigo_http: result.status,
          duracion_ms: Date.now() - start,
          payload_json: payload,
          respuesta_json: result.body,
          xml_path: xmlPath,
          hash_documento: cleanText(result.body?.hash),
          descripcion_sunat:
            'XML generado en beta. La GRE no fue enviada a SUNAT y no tiene validez tributaria.',
          ambiente_emision: 'beta',
          es_prueba: true,
        })
      } else {
        const definitive = [400, 409, 422].includes(result.status)
        const state = 'pendiente_reintento'
        const message = responseMessage(
          result.body,
          definitive
            ? 'APIsPERU rechazó los datos usados para generar el XML de prueba.'
            : 'No se pudo generar el XML de prueba temporalmente.',
        )
        await finalize(context, guiaId, bloqueoToken, state, {
          intento_id: intentoId,
          codigo_http: result.status,
          duracion_ms: Date.now() - start,
          payload_json: payload,
          respuesta_json: result.body,
          ...(xmlPath ? { xml_path: xmlPath } : {}),
          codigo_error: responseCode(result.body),
          mensaje_error: message,
          descripcion_sunat: message,
          error_tipo: definitive ? 'validacion_beta' : 'conexion_beta',
          ambiente_emision: 'beta',
          es_prueba: true,
        })
      }
      return localResponse(context, guiaId)
    }

    remoteRequestStarted = true
    const result = await fetchJson(
      `${apiBaseUrl()}/despatch/send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${requiredEnv('APIS_PERU_TOKEN')}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      },
      SEND_TIMEOUT_MS,
    )

    const xmlPath = await saveXml(
      context.admin,
      loaded.guia,
      loaded.company,
      result.body,
    )
    const cdrPath = await saveCdr(
      context.admin,
      loaded.guia,
      loaded.company,
      result.body,
    )
    const ticket = cleanText(
      result.body?.sunatResponse?.ticket || result.body?.ticket,
    )

    if (acceptedByCdr(result.body)) {
      const pdfPath = await generatePdf(
        context.admin,
        loaded.guia,
        loaded.company,
        payload,
      )
      await finalize(context, guiaId, bloqueoToken, 'aceptado', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        ...(cdrPath ? { cdr_path: cdrPath } : {}),
        ...(pdfPath ? { pdf_path: pdfPath } : {}),
        ticket_sunat: ticket,
        hash_documento: cleanText(result.body?.hash),
        codigo_sunat: responseCode(result.body) || '0',
        descripcion_sunat: responseMessage(result.body, 'Guía aceptada por SUNAT'),
        observaciones_sunat: responseNotes(result.body),
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    } else if (rejectedByCdr(result.body)) {
      await finalize(context, guiaId, bloqueoToken, 'rechazado', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        ...(cdrPath ? { cdr_path: cdrPath } : {}),
        codigo_error: responseCode(result.body),
        mensaje_error: responseMessage(result.body, 'La GRE fue rechazada por SUNAT.'),
        descripcion_sunat: responseMessage(result.body, 'La GRE fue rechazada por SUNAT.'),
        observaciones_sunat: responseNotes(result.body),
        error_tipo: 'sunat',
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    } else if (ticket) {
      const pdfPath = await generatePdf(
        context.admin,
        loaded.guia,
        loaded.company,
        payload,
      )
      await finalize(context, guiaId, bloqueoToken, 'ticket_pendiente', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ticket_sunat: ticket,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        ...(pdfPath ? { pdf_path: pdfPath } : {}),
        hash_documento: cleanText(result.body?.hash),
        descripcion_sunat:
          'Guía enviada. Ticket recibido; falta consultar el CDR.',
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    } else if ([401, 403, 404, 429].includes(result.status)) {
      const message = responseMessage(
        result.body,
        'El proveedor rechazó la autenticación o limitó la solicitud antes de enviarla a SUNAT. Corrige la configuración y reintenta.',
      )
      await finalize(context, guiaId, bloqueoToken, 'pendiente_reintento', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        codigo_error: responseCode(result.body),
        mensaje_error: message,
        descripcion_sunat: message,
        error_tipo: 'configuracion_proveedor',
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    } else if ([400, 422].includes(result.status)) {
      const message = responseMessage(
        result.body,
        'APIsPERU detectó errores de validación antes de devolver ticket o CDR. Corrige los datos y reintenta.',
      )
      await finalize(context, guiaId, bloqueoToken, 'pendiente_reintento', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        codigo_error: responseCode(result.body),
        mensaje_error: message,
        descripcion_sunat: message,
        error_tipo: 'validacion_proveedor',
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    } else {
      const message = responseMessage(
        result.body,
        'No se recibió ticket ni CDR definitivo. La GRE debe reconciliarse antes de otro envío.',
      )
      await finalize(context, guiaId, bloqueoToken, 'resultado_incierto', {
        intento_id: intentoId,
        codigo_http: result.status,
        duracion_ms: Date.now() - start,
        payload_json: payload,
        respuesta_json: result.body,
        ...(xmlPath ? { xml_path: xmlPath } : {}),
        mensaje_error: message,
        descripcion_sunat: message,
        error_tipo: 'resultado_incierto_proveedor',
        ambiente_emision: 'produccion',
        es_prueba: false,
      })
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const state = remoteRequestStarted
      ? 'resultado_incierto'
      : 'pendiente_reintento'
    const description = remoteRequestStarted
      ? 'No se confirmó el resultado del envío. La GRE debe reconciliarse antes de habilitar otro intento.'
      : isBeta
        ? 'No se pudo generar el XML de prueba. Se puede intentar nuevamente sin riesgo tributario.'
        : 'La GRE no llegó a enviarse al proveedor. Corrige el problema y vuelve a intentarlo.'

    await finalize(context, guiaId, bloqueoToken, state, {
      intento_id: intentoId,
      duracion_ms: Date.now() - start,
      ...(payload ? { payload_json: payload } : {}),
      mensaje_error: remoteRequestStarted
        ? `Resultado remoto incierto: ${message}`
        : message,
      descripcion_sunat: description,
      error_tipo: remoteRequestStarted
        ? (error instanceof DOMException && error.name === 'AbortError'
            ? 'resultado_incierto_timeout'
            : 'resultado_incierto_conexion')
        : isBeta
          ? 'conexion_beta'
          : 'validacion_local',
      ambiente_emision: environment,
      es_prueba: isBeta,
    })
  }

  return localResponse(context, guiaId)
}

export async function consultarGuiaCore(
  context: GreContext,
  guiaId: string,
  consultarSunat: boolean,
): Promise<any> {
  if (!consultarSunat) return localResponse(context, guiaId)

  const loaded = await loadGuide(context.admin, guiaId)
  const ambienteDocumento = cleanText(loaded.guia.ambiente_emision).toLowerCase()
  const environment = apiEnvironment()

  if (loaded.guia.es_prueba === true || ambienteDocumento === 'beta') {
    return {
      ...(await localResponse(context, guiaId)),
      mensaje:
        'La GRE es de prueba beta. Solo contiene XML validado y no tiene ticket ni CDR SUNAT para consultar.',
    }
  }

  if (ambienteDocumento === 'produccion' && environment !== 'produccion') {
    throw new HttpError(
      409,
      'La GRE pertenece a producción. Configura APIS_PERU_ENVIRONMENT=produccion antes de consultar su ticket.',
    )
  }

  return consultTicket(context, guiaId)
}
