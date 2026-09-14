import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.4'

type ObservationOutcome = 'succeeded' | 'failed' | 'denied' | 'skipped'

type ObservationState = {
  traceId: string
  component: string
  method: string
  startedAt: number
  organizationId: string | null
  jobId: string | null
  outcomeOverride: ObservationOutcome | null
  errorCodeOverride: string | null
}

const observations = new WeakMap<Request, ObservationState>()
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const COMPONENT_RE = /^[a-z0-9][a-z0-9._-]{0,79}$/
const ERROR_CODE_RE = /^[A-Z0-9][A-Z0-9._:-]{0,79}$/
const OBSERVABILITY_JSON_PREFIXES = [
  '{"kind":"stomni_observability"',
  '{"kind":"stomni_observability_internal"',
]

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`Missing observability environment: ${name}`)
  return value
}

function serviceClient() {
  return createClient(
    requiredEnv('SUPABASE_URL'),
    requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
    { auth: { persistSession: false, autoRefreshToken: false } },
  )
}

function normalizeTraceId(req: Request): string {
  const candidate = req.headers.get('x-stomni-trace-id')?.trim() ?? ''
  return UUID_RE.test(candidate) ? candidate.toLowerCase() : crypto.randomUUID()
}

function normalizeErrorCode(value: unknown): string | null {
  const normalized = String(value ?? '').trim().toUpperCase()
  return ERROR_CODE_RE.test(normalized) ? normalized : null
}

function sanitizedErrorCode(error: unknown): string {
  if (error && typeof error === 'object') {
    const record = error as Record<string, unknown>
    for (const candidate of [record.code, record.name]) {
      const value = normalizeErrorCode(candidate)
      if (value) return value
    }
  }
  return 'UNHANDLED_ERROR'
}

function sanitizeConsoleString(value: string): string {
  if (OBSERVABILITY_JSON_PREFIXES.some((prefix) => value.startsWith(prefix))) {
    return value
  }

  return value
    .replace(/Bearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [redacted]')
    .replace(/\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, '[redacted-jwt]')
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[redacted-email]')
    .replace(/https?:\/\/\S+/gi, '[redacted-url]')
    .replace(/\b\d{8,15}\b/g, '[redacted-number]')
    .slice(0, 400)
}

function sanitizeConsoleValue(value: unknown): unknown {
  if (typeof value === 'string') return sanitizeConsoleString(value)
  if (
    value === null ||
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    typeof value === 'undefined'
  ) {
    return value
  }

  if (value instanceof Error) {
    return {
      name: normalizeErrorCode(value.name) ?? 'ERROR',
      code: sanitizedErrorCode(value),
    }
  }

  // Objetos de SDK/provider pueden incluir headers, request bodies, URLs,
  // documentos o secretos. No se serializan de forma genérica.
  return '[redacted-object]'
}

function installConsoleGuard(): void {
  const globalRecord = globalThis as unknown as Record<PropertyKey, unknown>
  const marker = Symbol.for('stomni.observability.console_guard')
  if (globalRecord[marker] === true) return

  const originalLog = console.log.bind(console)
  const originalWarn = console.warn.bind(console)
  const originalError = console.error.bind(console)

  console.log = (...args: unknown[]) => originalLog(...args.map(sanitizeConsoleValue))
  console.warn = (...args: unknown[]) => originalWarn(...args.map(sanitizeConsoleValue))
  console.error = (...args: unknown[]) => originalError(...args.map(sanitizeConsoleValue))
  globalRecord[marker] = true
}

// Cada Edge Function observada importa este módulo antes de ejecutar handlers.
// El guard cubre también logs emitidos por helpers compartidos y SDKs cargados en
// el mismo isolate, evitando que errores legacy vuelquen PII o secretos crudos.
installConsoleGuard()

function statusOutcome(status: number): ObservationOutcome {
  if (status === 204) return 'skipped'
  if (status === 401 || status === 403) return 'denied'
  return status >= 400 ? 'failed' : 'succeeded'
}

function severityFor(outcome: ObservationOutcome): 'info' | 'warn' | 'error' {
  if (outcome === 'failed') return 'error'
  if (outcome === 'denied') return 'warn'
  return 'info'
}

function responseWithTrace(response: Response, traceId: string): Response {
  const headers = new Headers(response.headers)
  headers.set('x-stomni-trace-id', traceId)
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  })
}

async function persistObservation(
  state: ObservationState,
  status: number,
  errorCode: string | null,
): Promise<void> {
  const outcome = state.outcomeOverride
    ?? (state.method === 'OPTIONS' ? 'skipped' : statusOutcome(status))
  const effectiveErrorCode = state.errorCodeOverride ?? errorCode
  const durationMs = Math.max(0, Math.min(Math.round(performance.now() - state.startedAt), 86400000))
  const event = {
    kind: 'stomni_observability',
    trace_id: state.traceId,
    job_id: state.jobId,
    organization_id: state.organizationId,
    component: state.component,
    event_name: 'request.completed',
    severity: severityFor(outcome),
    outcome,
    duration_ms: durationMs,
    http_status: status,
    error_code: effectiveErrorCode,
  }

  // Structured console event intentionally contains no request/response body,
  // raw error message, email, document number, token, cookie or secret.
  console.log(JSON.stringify(event))

  try {
    const { error } = await serviceClient().rpc('record_observability_event_v1', {
      p_organization_id: state.organizationId,
      p_trace_id: state.traceId,
      p_component: state.component,
      p_event_name: 'request.completed',
      p_severity: event.severity,
      p_outcome: outcome,
      p_duration_ms: durationMs,
      p_http_status: status,
      p_error_code: effectiveErrorCode,
      p_job_id: state.jobId,
    })
    if (error) {
      console.warn(JSON.stringify({
        kind: 'stomni_observability_internal',
        trace_id: state.traceId,
        component: state.component,
        outcome: 'persist_failed',
        error_code: 'OBSERVABILITY_PERSIST_FAILED',
      }))
    }
  } catch {
    // Observability is fail-open for the business operation. Never serialize the
    // caught error because provider/client errors may contain sensitive details.
    console.warn(JSON.stringify({
      kind: 'stomni_observability_internal',
      trace_id: state.traceId,
      component: state.component,
      outcome: 'persist_failed',
      error_code: 'OBSERVABILITY_PERSIST_FAILED',
    }))
  }
}

export function bindObservationTenant(req: Request, organizationId: string | null): void {
  const state = observations.get(req)
  if (!state) return
  const normalized = String(organizationId ?? '').trim().toLowerCase()
  if (!normalized || !UUID_RE.test(normalized)) return
  state.organizationId = normalized
}

export function bindObservationJob(req: Request, jobId: string | null): void {
  const state = observations.get(req)
  if (!state) return
  const normalized = String(jobId ?? '').trim().toLowerCase()
  if (!normalized || !UUID_RE.test(normalized)) return
  state.jobId = normalized
}

export function markObservationOutcome(
  req: Request,
  outcome: ObservationOutcome,
  errorCode: string | null = null,
): void {
  const state = observations.get(req)
  if (!state) return
  state.outcomeOverride = outcome
  state.errorCodeOverride = errorCode === null ? null : normalizeErrorCode(errorCode)
}

export function observationTraceId(req: Request): string | null {
  return observations.get(req)?.traceId ?? null
}

export function serveObserved(
  component: string,
  handler: (req: Request) => Promise<Response> | Response,
): (req: Request) => Promise<Response> {
  const normalizedComponent = component.trim().toLowerCase()
  if (!COMPONENT_RE.test(normalizedComponent)) {
    throw new Error('Invalid static observability component')
  }

  return async (req: Request): Promise<Response> => {
    const state: ObservationState = {
      traceId: normalizeTraceId(req),
      component: normalizedComponent,
      method: req.method.toUpperCase(),
      startedAt: performance.now(),
      organizationId: null,
      jobId: null,
      outcomeOverride: null,
      errorCodeOverride: null,
    }
    observations.set(req, state)

    try {
      const response = await handler(req)
      await persistObservation(
        state,
        response.status,
        response.status >= 400 ? `HTTP_${response.status}` : null,
      )
      return responseWithTrace(response, state.traceId)
    } catch (error) {
      await persistObservation(state, 500, sanitizedErrorCode(error))
      throw error
    } finally {
      observations.delete(req)
    }
  }
}
