-- Fase 8.2: progreso guiado de configuración por tenant.
-- Sólo guarda workflow/acknowledgement; no duplica perfil, capabilities ni estructura operativa.
BEGIN;

CREATE TABLE public.organization_onboarding_progress (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'in_progress' CHECK(status IN ('in_progress','completed')),
  completed_steps text[] NOT NULL DEFAULT '{}'::text[],
  revision bigint NOT NULL DEFAULT 1 CHECK(revision>=1),
  started_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CHECK (completed_steps <@ ARRAY['business_profile','modules','operations','review']::text[]),
  CHECK (status<>'completed' OR completed_steps @> ARRAY['business_profile','modules','operations','review']::text[]),
  CHECK ((status='completed')=(completed_at IS NOT NULL))
);

-- Tenants existentes al introducir F8.2 no son obligados a repetir onboarding.
INSERT INTO public.organization_onboarding_progress(
  organization_id,status,completed_steps,completed_at
)
SELECT o.id,'completed',ARRAY['business_profile','modules','operations','review']::text[],now()
FROM public.organizations o
ON CONFLICT(organization_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.create_default_organization_onboarding_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
BEGIN
  INSERT INTO public.organization_onboarding_progress(organization_id)
  VALUES(NEW.id)
  ON CONFLICT(organization_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.create_default_organization_onboarding_progress() FROM PUBLIC,anon,authenticated;

CREATE TRIGGER organizations_create_onboarding_progress
AFTER INSERT ON public.organizations
FOR EACH ROW EXECUTE FUNCTION private.create_default_organization_onboarding_progress();

ALTER TABLE public.organization_onboarding_progress ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.organization_onboarding_progress FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.organization_onboarding_progress TO authenticated;
CREATE POLICY organization_onboarding_progress_tenant_read
ON public.organization_onboarding_progress
FOR SELECT TO authenticated
USING(private.row_belongs_to_current_organization(organization_id) AND private.has_permission('tenant.read'));

CREATE OR REPLACE FUNCTION public.get_my_onboarding_progress_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_row public.organization_onboarding_progress;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Not authorized to read onboarding progress';
  END IF;
  SELECT * INTO v_row
  FROM public.organization_onboarding_progress p
  WHERE p.organization_id=v_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Onboarding progress not found';
  END IF;
  RETURN jsonb_build_object(
    'status',v_row.status,
    'completed_steps',to_jsonb(v_row.completed_steps),
    'revision',v_row.revision,
    'started_at',v_row.started_at,
    'completed_at',v_row.completed_at,
    'next_step',CASE
      WHEN NOT ('business_profile'=ANY(v_row.completed_steps)) THEN 'business_profile'
      WHEN NOT ('modules'=ANY(v_row.completed_steps)) THEN 'modules'
      WHEN NOT ('operations'=ANY(v_row.completed_steps)) THEN 'operations'
      WHEN NOT ('review'=ANY(v_row.completed_steps)) THEN 'review'
      ELSE NULL
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_my_onboarding_step_v1(
  p_expected_revision bigint,
  p_step text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_step text:=lower(btrim(coalesce(p_step,'')));
  v_row public.organization_onboarding_progress;
  v_expected_step text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Tenant admin permission required';
  END IF;
  IF v_step NOT IN ('business_profile','modules','operations','review') THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Unsupported onboarding step';
  END IF;

  SELECT * INTO v_row
  FROM public.organization_onboarding_progress p
  WHERE p.organization_id=v_org
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0002',MESSAGE='Onboarding progress not found'; END IF;
  IF p_expected_revision IS NULL OR p_expected_revision<>v_row.revision THEN
    RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='Onboarding progress changed; reload before continuing';
  END IF;
  IF v_row.status='completed' THEN RETURN public.get_my_onboarding_progress_v1(); END IF;

  v_expected_step:=CASE
    WHEN NOT ('business_profile'=ANY(v_row.completed_steps)) THEN 'business_profile'
    WHEN NOT ('modules'=ANY(v_row.completed_steps)) THEN 'modules'
    WHEN NOT ('operations'=ANY(v_row.completed_steps)) THEN 'operations'
    WHEN NOT ('review'=ANY(v_row.completed_steps)) THEN 'review'
    ELSE NULL
  END;
  IF v_step<>v_expected_step THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Onboarding steps must be completed in order';
  END IF;

  -- Verifica que la fuente autoritativa de cada paso exista antes de reconocerlo.
  IF v_step='business_profile' AND NOT EXISTS(
    SELECT 1 FROM public.configuracion_negocio c WHERE c.organization_id=v_org
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Business profile must exist before completing this step';
  ELSIF v_step='modules' AND NOT EXISTS(
    SELECT 1 FROM public.business_capabilities b WHERE b.organization_id=v_org
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Business capabilities must exist before completing this step';
  ELSIF v_step='operations' AND (
    NOT EXISTS(SELECT 1 FROM public.branches b WHERE b.organization_id=v_org AND b.is_main AND b.status='active')
    OR NOT EXISTS(SELECT 1 FROM public.cash_registers c WHERE c.organization_id=v_org AND c.is_default AND c.status='active')
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Main branch and default cash register must exist before completing operations';
  END IF;

  UPDATE public.organization_onboarding_progress p
  SET completed_steps=array_append(p.completed_steps,v_step),
      status=CASE WHEN v_step='review' THEN 'completed' ELSE 'in_progress' END,
      completed_at=CASE WHEN v_step='review' THEN clock_timestamp() ELSE NULL END,
      revision=p.revision+1,
      updated_at=clock_timestamp()
  WHERE p.organization_id=v_org
  RETURNING * INTO v_row;

  RETURN public.get_my_onboarding_progress_v1();
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_onboarding_progress_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.complete_my_onboarding_step_v1(bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_my_onboarding_progress_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_my_onboarding_step_v1(bigint,text) TO authenticated;

COMMENT ON TABLE public.organization_onboarding_progress IS
  'Workflow UX de onboarding por tenant. No replica valores de perfil, módulos, sucursales, cajas ni branding.';

COMMIT;
