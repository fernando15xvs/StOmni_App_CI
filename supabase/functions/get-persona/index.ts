import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import {
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

type TipoDocumento = 'dni' | 'ruc'

class HttpError extends Error {
  status: number

  constructor(message: string, status: number) {
    super(message)
    this.status = status
  }
}

function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    },
  })
}

function normalizarTexto(value: unknown): string | null {
  if (typeof value !== 'string') return null

  const texto = value.trim().replace(/\s+/g, ' ')
  return texto.length > 0 ? texto : null
}

function construirNombreCompleto(apiData: Record<string, unknown>): string | null {
  const partes = [
    normalizarTexto(apiData.nombres),
    normalizarTexto(apiData.apellidoPaterno),
    normalizarTexto(apiData.apellidoMaterno),
  ].filter((valor): valor is string => valor !== null)

  return partes.length > 0 ? partes.join(' ') : null
}

serve(serveObserved('get-persona', async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      status: 200,
      headers: corsHeaders,
    })
  }

  if (req.method !== 'POST') {
    return jsonResponse(
      { error: 'Método no permitido. Utilice POST.' },
      405,
    )
  }

  try {
    // DNI/RUC usa service-role para caché, por lo que primero exigimos una
    // sesión real vinculada a un empleado activo con rol técnico vigente.
    const context = await requireEmployee(req)
    const supabaseAdmin = context.admin

    let body: Record<string, unknown>

    try {
      body = await req.json()
    } catch {
      throw new HttpError('El cuerpo de la solicitud no es JSON válido.', 400)
    }

    const numero = String(body.numero ?? '')
      .trim()
      .replace(/\s+/g, '')

    const tipo = String(body.tipo ?? '')
      .trim()
      .toLowerCase() as TipoDocumento

    if (!numero || !tipo) {
      throw new HttpError(
        'Faltan los parámetros numero o tipo.',
        400,
      )
    }

    if (tipo !== 'dni' && tipo !== 'ruc') {
      throw new HttpError(
        'El tipo de documento debe ser dni o ruc.',
        400,
      )
    }

    if (tipo === 'dni' && !/^\d{8}$/.test(numero)) {
      throw new HttpError(
        'El DNI debe contener exactamente 8 dígitos.',
        400,
      )
    }

    if (tipo === 'ruc' && !/^\d{11}$/.test(numero)) {
      throw new HttpError(
        'El RUC debe contener exactamente 11 dígitos.',
        400,
      )
    }

    const apisPeruToken = Deno.env.get('APIS_PERU_DNIRUC_TOKEN')

    if (!apisPeruToken) {
      console.error('get-persona provider token missing')
      throw new HttpError(
        'El servicio de consulta DNI/RUC no está configurado.',
        500,
      )
    }

    // 1. Consultar caché mediante el cliente admin que ya fue creado por el
    // guard de autenticación. La service role nunca se envía a Flutter.
    const { data: cacheData, error: cacheError } = await supabaseAdmin
      .from('personas_cache')
      .select(`
        id,
        tipo,
        numero,
        nombres,
        apellido_paterno,
        apellido_materno,
        nombre_completo,
        razon_social,
        data,
        created_at
      `)
      .eq('numero', numero)
      .eq('tipo', tipo)
      .maybeSingle()

    if (cacheError) {
      console.error('get-persona cache read failed')
      throw new HttpError(
        'No se pudo consultar la caché.',
        500,
      )
    }

    if (cacheData) {
      return jsonResponse({
        success: true,
        source: 'cache',
        data: cacheData,
      })
    }

    // 2. Consultar APIsPeru. El documento se usa en la URL de salida pero nunca
    // se registra en observabilidad ni en logs técnicos.
    const apiUrl =
      `https://dniruc.apisperu.com/api/v1/${tipo}/${numero}`
    let response: Response

    try {
      response = await fetch(apiUrl, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          Authorization: `Bearer ${apisPeruToken}`,
          'Cache-Control': 'no-cache',
        },
        signal: AbortSignal.timeout(10000),
      })
    } catch {
      console.error('get-persona provider connection failed')
      throw new HttpError(
        'No se pudo conectar con el servicio de consulta.',
        502,
      )
    }

    let apiData: Record<string, unknown> | null = null

    try {
      apiData = await response.json()
    } catch {
      console.error(`get-persona provider invalid json status=${response.status}`)
    }

    if (response.status === 404) {
      throw new HttpError(
        'Documento no encontrado.',
        404,
      )
    }

    if (response.status === 401 || response.status === 403) {
      console.error('get-persona provider authorization rejected')
      throw new HttpError(
        'El servicio de consulta no está autorizado.',
        502,
      )
    }

    if (response.status === 429) {
      throw new HttpError(
        'Se alcanzó el límite de consultas. Intente más tarde.',
        429,
      )
    }

    if (!response.ok) {
      console.error(`get-persona provider failed status=${response.status}`)
      throw new HttpError(
        'El proveedor de consulta no está disponible.',
        502,
      )
    }

    if (!apiData) {
      throw new HttpError(
        'APIsPeru devolvió una respuesta vacía.',
        502,
      )
    }

    const documentoRespuesta =
      tipo === 'dni'
        ? String(apiData.dni ?? '')
        : String(apiData.ruc ?? '')

    if (documentoRespuesta !== numero) {
      throw new HttpError(
        'Documento no encontrado o inválido.',
        404,
      )
    }

    const nombres = normalizarTexto(apiData.nombres)
    const apellidoPaterno = normalizarTexto(apiData.apellidoPaterno)
    const apellidoMaterno = normalizarTexto(apiData.apellidoMaterno)
    const razonSocial = normalizarTexto(apiData.razonSocial)

    const nombreCompleto =
      tipo === 'dni'
        ? construirNombreCompleto(apiData)
        : null

    if (tipo === 'dni' && !nombreCompleto) {
      throw new HttpError(
        'No se encontraron nombres para el DNI.',
        404,
      )
    }

    if (tipo === 'ruc' && !razonSocial) {
      throw new HttpError(
        'No se encontró la razón social del RUC.',
        404,
      )
    }

    const cachePayload = {
      tipo,
      numero,
      nombres,
      apellido_paterno: apellidoPaterno,
      apellido_materno: apellidoMaterno,
      nombre_completo: nombreCompleto,
      razon_social: razonSocial,
      data: apiData,
    }

    // 3. Guardar evitando errores por consultas simultáneas.
    const { data: savedData, error: saveError } = await supabaseAdmin
      .from('personas_cache')
      .upsert(cachePayload, {
        onConflict: 'numero',
      })
      .select(`
        id,
        tipo,
        numero,
        nombres,
        apellido_paterno,
        apellido_materno,
        nombre_completo,
        razon_social,
        data,
        created_at
      `)
      .single()

    if (saveError) {
      console.error('get-persona cache write failed')

      // La consulta fue exitosa, aunque la caché haya fallado.
      return jsonResponse({
        success: true,
        source: 'api',
        cache_saved: false,
        data: cachePayload,
      })
    }

    return jsonResponse({
      success: true,
      source: 'api',
      cache_saved: true,
      data: savedData,
    })
  } catch (error: unknown) {
    const status = error instanceof AuthGuardError
      ? error.status
      : error instanceof HttpError
      ? error.status
      : 500

    const message = error instanceof Error
      ? error.message
      : 'Error interno desconocido.'

    if (status >= 500) {
      // No serializar el error crudo: errores de Supabase/proveedor pueden
      // incluir datos sensibles, URLs o valores derivados del request.
      console.error(`get-persona failed status=${status}`)
    }

    return jsonResponse(
      {
        success: false,
        error: message,
      },
      status,
    )
  }
}))
