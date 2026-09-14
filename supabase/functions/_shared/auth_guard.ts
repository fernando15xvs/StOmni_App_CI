import {
  createClient,
  SupabaseClient,
  User,
} from 'https://esm.sh/@supabase/supabase-js@2.49.4'
import { bindObservationTenant } from './observability.ts'

export type AppRole = 'admin' | 'operador'

export type EmployeeIdentity = {
  id: number
  authId: string
  organizationId: string
  nombre: string
  rol: AppRole
}

export type AuthorizedEmployeeContext = {
  admin: SupabaseClient
  user: User
  organizationId: string
  employee: EmployeeIdentity
}

export class AuthGuardError extends Error {
  status: number
  details?: unknown

  constructor(status: number, message: string, details?: unknown) {
    super(message)
    this.name = 'AuthGuardError'
    this.status = status
    this.details = details
  }
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) {
    throw new AuthGuardError(500, `Falta el secreto ${name}`)
  }
  return value
}

export function createAdminClient(): SupabaseClient {
  return createClient(
    requiredEnv('SUPABASE_URL'),
    requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
    { auth: { persistSession: false, autoRefreshToken: false } },
  )
}

const TENANT_HEADER = 'x-stomni-organization-id'
const FISCAL_STORAGE_BUCKET = 'comprobantes-electronicos'

// Tablas tenant-owned que pueden ser consultadas directamente por los helpers
// Edge usando service_role. gre_ubigeos/personas_cache quedan fuera porque son
// catálogos/plataforma globales según el contrato SaaS.
const TENANT_DATA_API_TABLES = new Set([
  'empleados',
  'configuracion_negocio',
  'business_capabilities',
  'clientes',
  'proveedores',
  'categorias',
  'productos',
  'product_presentations',
  'product_variants',
  'product_variant_values',
  'product_attribute_definitions',
  'product_attribute_values',
  'almacenes',
  'inventario_almacen',
  'movimientos_inventario',
  'transferencias_stock',
  'inventory_lots',
  'inventory_serials',
  'inventory_traceability_allocations',
  'inventory_requests',
  'ventas',
  'detalle_ventas',
  'pagos_venta',
  'cotizaciones',
  'detalle_cotizaciones',
  'pagos_deuda_requests',
  'ventas_requests_anulados',
  'constancias_descuento',
  'purchase_orders',
  'purchase_order_lines',
  'purchase_receipts',
  'purchase_receipt_lines',
  'gastos',
  'pagos_gasto',
  'series_comprobantes',
  'comprobantes_electronicos',
  'facturacion_intentos',
  'notas_credito',
  'notas_credito_detalles',
  'notas_credito_intentos',
  'gre_transportistas',
  'gre_transportistas_agencias',
  'gre_conductores',
  'gre_vehiculos',
  'guias_remision',
  'guias_remision_detalles',
  'guias_remision_intentos',
  'solicitudes_baja_tributaria',
  'procesos_tributarios',
  'procesos_tributarios_detalles',
  'procesos_tributarios_intentos',
  'correlativos_procesos_tributarios',
  'documentos_tributarios_reconciliaciones',
])

function scopeFiscalStorageWriteUrl(
  url: URL,
  organizationId: string,
  method: string,
): void {
  if (!['POST', 'PUT', 'PATCH'].includes(method.toUpperCase())) return

  const marker = '/storage/v1/object/'
  const markerIndex = url.pathname.indexOf(marker)
  if (markerIndex < 0) return

  const prefix = url.pathname.slice(0, markerIndex + marker.length)
  const parts = url.pathname
    .slice(markerIndex + marker.length)
    .split('/')
    .filter((part) => part.length > 0)

  if (parts.length < 2) return

  // Sólo se reescriben escrituras directas /object/<bucket>/<path>.
  // sign/public/list se dejan intactos para que documentos legacy ya existentes
  // continúen resolviendo su ruta histórica. Los paths nuevos quedan guardados
  // con organization_id por trigger SQL y por tanto no necesitan reescritura al leer.
  const first = decodeURIComponent(parts[0])
  if (['sign', 'public', 'list', 'copy', 'move'].includes(first)) return
  if (first !== FISCAL_STORAGE_BUCKET) return

  const firstPathSegment = decodeURIComponent(parts[1] ?? '')
  if (firstPathSegment === organizationId) return

  parts.splice(1, 0, encodeURIComponent(organizationId))
  url.pathname = `${prefix}${parts.join('/')}`
}

async function forwardScopedFetch(
  input: RequestInfo | URL,
  init: RequestInit | undefined,
  organizationId: string,
): Promise<Response> {
  const sourceUrl = input instanceof Request ? input.url : String(input)
  const url = new URL(sourceUrl)
  const method = String(init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase()
  const marker = '/rest/v1/'
  const markerIndex = url.pathname.indexOf(marker)

  if (markerIndex >= 0) {
    const resource = decodeURIComponent(
      url.pathname.slice(markerIndex + marker.length).split('/')[0] ?? '',
    )
    if (resource && resource !== 'rpc' && TENANT_DATA_API_TABLES.has(resource)) {
      // set(), no append(): incluso si un helper intenta construir otro filtro,
      // el tenant resuelto server-side prevalece.
      url.searchParams.set('organization_id', `eq.${organizationId}`)

      // Compatibilidad fiscal transitoria: dos helpers legacy todavía piden
      // configuracion_negocio.id=1. Después de imponer organization_id, ese
      // filtro ya no es autoridad y rompería organizaciones cuyo id interno no
      // sea 1. Se elimina únicamente en esta tabla y únicamente para service_role
      // tenant-scoped; la fila sigue siendo única por organization_id.
      if (
        resource === 'configuracion_negocio' &&
        url.searchParams.get('id') === 'eq.1'
      ) {
        url.searchParams.delete('id')
      }
    }
  }

  scopeFiscalStorageWriteUrl(url, organizationId, method)

  const headers = new Headers(input instanceof Request ? input.headers : undefined)
  if (init?.headers) {
    new Headers(init.headers).forEach((value, key) => headers.set(key, value))
  }
  // Header interno entre Edge y PostgREST. El valor proviene exclusivamente de
  // app_users -> organizations; nunca se copia del request original del cliente.
  headers.set(TENANT_HEADER, organizationId)

  if (!(input instanceof Request)) {
    return fetch(url.toString(), { ...init, headers })
  }

  const source = input.clone()
  const body = method === 'GET' || method === 'HEAD'
    ? undefined
    : await source.arrayBuffer()
  return fetch(url.toString(), {
    ...init,
    method: source.method,
    headers,
    body,
    redirect: source.redirect,
    signal: init?.signal ?? source.signal,
  })
}

function createTenantAdminClient(organizationId: string): SupabaseClient {
  const scopedFetch: typeof fetch = (input, init) =>
    forwardScopedFetch(input, init, organizationId)

  return createClient(
    requiredEnv('SUPABASE_URL'),
    requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { fetch: scopedFetch },
    },
  )
}

function normalizeRole(value: unknown): AppRole | null {
  const role = String(value ?? '').trim().toLowerCase()

  if (role === 'admin') return 'admin'
  if (role === 'operador') return 'operador'

  return null
}

export async function requireEmployee(
  req: Request,
  allowedRoles: readonly AppRole[] = ['admin', 'operador'],
): Promise<AuthorizedEmployeeContext> {
  const bootstrapAdmin = createAdminClient()
  const authHeader = req.headers.get('Authorization') ?? ''
  const token = authHeader.replace(/^Bearer\s+/i, '').trim()

  if (!token) {
    throw new AuthGuardError(401, 'Usuario no autenticado')
  }

  const { data: authData, error: authError } = await bootstrapAdmin.auth.getUser(token)
  if (authError || !authData.user) {
    throw new AuthGuardError(401, 'Sesión inválida o vencida', authError)
  }

  // service_role bypasses RLS. Por eso el tenant se resuelve explícitamente
  // desde app_users y nunca desde metadata del JWT, body, query ni headers.
  const { data: membership, error: membershipError } = await bootstrapAdmin
    .from('app_users')
    .select('organization_id, status, base_role, organizations!inner(status)')
    .eq('user_id', authData.user.id)
    .maybeSingle()

  if (membershipError) {
    throw new AuthGuardError(
      500,
      'No se pudo resolver la organización del usuario',
      membershipError,
    )
  }

  const organizationId = String(membership?.organization_id ?? '').trim()
  const organizationRaw = membership?.organizations
  const organization = Array.isArray(organizationRaw)
    ? organizationRaw[0]
    : organizationRaw
  if (
    !organizationId ||
    membership?.status !== 'active' ||
    organization?.status !== 'active'
  ) {
    throw new AuthGuardError(
      403,
      'La cuenta no pertenece a una organización activa',
    )
  }

  const role = normalizeRole(membership?.base_role)
  if (!role || !allowedRoles.includes(role)) {
    throw new AuthGuardError(403, 'Rol no autorizado para esta operación')
  }

  // app_user_id es el vínculo canónico. auth_id se conserva sólo como fallback
  // de transición y siempre se consulta dentro de la organización ya resuelta.
  let { data: empleado, error: empleadoError } = await bootstrapAdmin
    .from('empleados')
    .select('id, app_user_id, auth_id, nombre, activo')
    .eq('organization_id', organizationId)
    .eq('app_user_id', authData.user.id)
    .maybeSingle()

  if (!empleado && !empleadoError) {
    const legacy = await bootstrapAdmin
      .from('empleados')
      .select('id, app_user_id, auth_id, nombre, activo')
      .eq('organization_id', organizationId)
      .eq('auth_id', authData.user.id)
      .maybeSingle()
    empleado = legacy.data
    empleadoError = legacy.error
  }

  if (empleadoError) {
    throw new AuthGuardError(
      500,
      'No se pudo validar el acceso del empleado',
      empleadoError,
    )
  }

  if (!empleado || empleado.activo !== true) {
    throw new AuthGuardError(
      403,
      'La cuenta no está vinculada a un empleado activo de su organización',
    )
  }

  // F9.4: el tenant sólo se enlaza al trace después de resolverlo desde
  // app_users/organizations. Nunca se toma de headers/body del cliente.
  bindObservationTenant(req, organizationId)

  const tenantAdmin = createTenantAdminClient(organizationId)
  return {
    admin: tenantAdmin,
    user: authData.user,
    organizationId,
    employee: {
      id: Number(empleado.id),
      authId: String(empleado.app_user_id ?? empleado.auth_id ?? authData.user.id),
      organizationId,
      nombre: String(empleado.nombre ?? '').trim(),
      rol: role,
    },
  }
}

export async function assertTenantResource(
  admin: SupabaseClient,
  organizationId: string,
  table: string,
  idColumn: string,
  id: string | number,
  label = 'Recurso',
): Promise<void> {
  const org = organizationId.trim()
  if (!org) throw new AuthGuardError(403, 'Organización activa requerida')

  const { data, error } = await admin
    .from(table)
    .select(idColumn)
    .eq('organization_id', org)
    .eq(idColumn, id)
    .maybeSingle()

  if (error) {
    throw new AuthGuardError(500, `No se pudo validar ${label}`, error)
  }
  if (!data) {
    // 404 deliberado: no revela si el ID existe en otro tenant.
    throw new AuthGuardError(404, `${label} no encontrado`)
  }
}

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder()
  const a = encoder.encode(left)
  const b = encoder.encode(right)
  if (a.length !== b.length) return false

  let difference = 0
  for (let index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index]
  }
  return difference === 0
}

export function requireSystemContext(req: Request): SupabaseClient {
  const expected = requiredEnv('FACTURACION_CRON_SECRET')
  const received = req.headers.get('x-cron-secret')?.trim() ?? ''
  if (!received || !constantTimeEqual(received, expected)) {
    throw new AuthGuardError(401, 'Credencial automática inválida')
  }
  return createAdminClient()
}