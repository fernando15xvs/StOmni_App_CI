-- F9.4 SaaS: observabilidad técnica tenant-aware sin payloads ni PII cruda.
BEGIN;

CREATE TABLE public.observability_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid NULL REFERENCES public.organizations(id) ON DELETE SET NULL,
  trace_id uuid NOT NULL,
  job_id uuid NULL,
  component text NOT NULL,
  event_name text NOT NULL DEFAULT 'request.completed',
  severity text NOT NULL,
  outcome text NOT NULL,
  duration_ms integer NULL,
  http_status smallint NULL,
  error_code text NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT observability_component_valid CHECK (
    component ~ '^[a-z0-9][a-z0-9._-]{0,79}$'
  ),
  CONSTRAINT observability_event_name_valid CHECK (
    event_name ~ '^[a-z0-9][a-z0-9._-]{0,79}$'
  ),
  CONSTRAINT observability_severity_valid CHECK (
    severity IN ('info','warn','error')
  ),
  CONSTRAINT observability_outcome_valid CHECK (
    outcome IN ('succeeded','failed','denied','skipped')
  ),
  CONSTRAINT observability_duration_valid CHECK (
    duration_ms IS NULL OR duration_ms BETWEEN 0 AND 86400000
  ),
  CONSTRAINT observability_http_status_valid CHECK (
    http_status IS NULL OR http_status BETWEEN 100 AND 599
  ),
  CONSTRAINT observability_error_code_valid CHECK (
    error_code IS NULL OR error_code ~ '^[A-Z0-9][A-Z0-9._:-]{0,79}$'
  )
);

COMMENT ON TABLE public.observability_events IS
  'Ledger técnico sanitizado. No admite request/response bodies, mensajes de error, emails, documentos, nombres, tokens ni secretos.';
COMMENT ON COLUMN public.observability_events.organization_id IS
  'Tenant resuelto server-side. NULL sólo para eventos de plataforma sin tenant.';
COMMENT ON COLUMN public.observability_events.error_code IS
  'Código técnico allowlisted/sanitizado; nunca el mensaje crudo de una excepción.';

CREATE INDEX observability_events_org_time_idx
  ON public.observability_events(organization_id,occurred_at DESC);
CREATE INDEX observability_events_trace_time_idx
  ON public.observability_events(trace_id,occurred_at DESC);
CREATE INDEX observability_events_job_time_idx
  ON public.observability_events(job_id,occurred_at DESC)
  WHERE job_id IS NOT NULL;
CREATE INDEX observability_events_component_time_idx
  ON public.observability_events(component,event_name,occurred_at DESC);

ALTER TABLE public.observability_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.observability_events FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.observability_events_id_seq FROM PUBLIC,anon,authenticated;

-- Writer interno usado por Edge Functions. La firma no acepta metadata libre ni
-- mensajes: la propia API hace imposible persistir payload/PII accidentalmente.
-- La autorización se controla por EXECUTE: PUBLIC/anon/authenticated no tienen
-- acceso y sólo service_role recibe GRANT. No se comprueba current_user dentro
-- de SECURITY DEFINER porque ahí current_user cambia al propietario de la función.
CREATE OR REPLACE FUNCTION public.record_observability_event_v1(
  p_organization_id uuid,
  p_trace_id uuid,
  p_component text,
  p_event_name text,
  p_severity text,
  p_outcome text,
  p_duration_ms integer DEFAULT NULL,
  p_http_status integer DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_job_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_component text := lower(btrim(coalesce(p_component,'')));
  v_event_name text := lower(btrim(coalesce(p_event_name,'')));
  v_severity text := lower(btrim(coalesce(p_severity,'')));
  v_outcome text := lower(btrim(coalesce(p_outcome,'')));
  v_error_code text := NULLIF(upper(btrim(coalesce(p_error_code,''))), '');
BEGIN
  IF p_trace_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='trace_id is required';
  END IF;
  IF p_organization_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organizations WHERE id=p_organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Unknown observability organization';
  END IF;
  IF v_component !~ '^[a-z0-9][a-z0-9._-]{0,79}$'
     OR v_event_name !~ '^[a-z0-9][a-z0-9._-]{0,79}$'
     OR v_severity NOT IN ('info','warn','error')
     OR v_outcome NOT IN ('succeeded','failed','denied','skipped')
     OR (p_duration_ms IS NOT NULL AND p_duration_ms NOT BETWEEN 0 AND 86400000)
     OR (p_http_status IS NOT NULL AND p_http_status NOT BETWEEN 100 AND 599)
     OR (v_error_code IS NOT NULL AND v_error_code !~ '^[A-Z0-9][A-Z0-9._:-]{0,79}$') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid sanitized observability event';
  END IF;

  INSERT INTO public.observability_events(
    organization_id,trace_id,job_id,component,event_name,severity,outcome,
    duration_ms,http_status,error_code
  ) VALUES (
    p_organization_id,p_trace_id,p_job_id,v_component,v_event_name,v_severity,
    v_outcome,p_duration_ms,p_http_status,v_error_code
  );
END;
$$;
REVOKE ALL ON FUNCTION public.record_observability_event_v1(
  uuid,uuid,text,text,text,text,integer,integer,text,uuid
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_observability_event_v1(
  uuid,uuid,text,text,text,text,integer,integer,text,uuid
) TO service_role;

-- Métricas agregadas tenant-safe para administración. No expone eventos globales,
-- actores ni datos de payload porque el ledger tampoco los almacena.
CREATE OR REPLACE FUNCTION public.get_observability_metrics_v1(
  p_hours integer DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_hours integer := LEAST(GREATEST(coalesce(p_hours,24),1),168);
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required';
  END IF;

  WITH scoped AS (
    SELECT *
    FROM public.observability_events
    WHERE organization_id=v_org
      AND occurred_at >= now() - make_interval(hours=>v_hours)
  ), totals AS (
    SELECT
      count(*)::bigint AS total_events,
      count(*) FILTER (WHERE outcome='succeeded')::bigint AS succeeded,
      count(*) FILTER (WHERE outcome='failed')::bigint AS failed,
      count(*) FILTER (WHERE outcome='denied')::bigint AS denied,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms)
        FILTER (WHERE duration_ms IS NOT NULL) AS p50_ms,
      percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
        FILTER (WHERE duration_ms IS NOT NULL) AS p95_ms,
      percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms)
        FILTER (WHERE duration_ms IS NOT NULL) AS p99_ms
    FROM scoped
  ), components AS (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'component',component,
      'events',events,
      'failed',failed,
      'denied',denied
    ) ORDER BY component),'[]'::jsonb) AS rows
    FROM (
      SELECT component,count(*)::bigint AS events,
        count(*) FILTER (WHERE outcome='failed')::bigint AS failed,
        count(*) FILTER (WHERE outcome='denied')::bigint AS denied
      FROM scoped
      GROUP BY component
    ) q
  )
  SELECT jsonb_build_object(
    'organization_id',v_org,
    'window_hours',v_hours,
    'total_events',t.total_events,
    'succeeded',t.succeeded,
    'failed',t.failed,
    'denied',t.denied,
    'p50_ms',t.p50_ms,
    'p95_ms',t.p95_ms,
    'p99_ms',t.p99_ms,
    'components',c.rows
  ) INTO v_result
  FROM totals t CROSS JOIN components c;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_observability_metrics_v1(integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_observability_metrics_v1(integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.list_recent_observability_errors_v1(
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  trace_id uuid,
  job_id uuid,
  component text,
  event_name text,
  severity text,
  outcome text,
  duration_ms integer,
  http_status smallint,
  error_code text,
  occurred_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_limit integer := LEAST(GREATEST(coalesce(p_limit,50),1),100);
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required';
  END IF;

  RETURN QUERY
  SELECT e.trace_id,e.job_id,e.component,e.event_name,e.severity,e.outcome,
    e.duration_ms,e.http_status,e.error_code,e.occurred_at
  FROM public.observability_events e
  WHERE e.organization_id=v_org
    AND e.outcome IN ('failed','denied')
  ORDER BY e.occurred_at DESC,e.id DESC
  LIMIT v_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.list_recent_observability_errors_v1(integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_recent_observability_errors_v1(integer)
  TO authenticated;

COMMIT;
