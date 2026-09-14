-- Fase 7.1: catálogo global de planes SaaS.
-- El catálogo define identidad/orden/visibilidad. Precios y provider price IDs quedan fuera
-- hasta F7.5 para no acoplar el dominio a un proveedor de pagos ni inventar importes.
BEGIN;

CREATE TABLE public.subscription_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 80),
  description text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  tier_rank integer NOT NULL UNIQUE CHECK (tier_rank BETWEEN 0 AND 1000),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  is_public boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(metadata)='object' AND pg_column_size(metadata) <= 8192),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.subscription_plans IS
  'Catálogo global de planes StOmni. No pertenece a un tenant y no contiene IDs/precios de proveedor de pagos.';

ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.subscription_plans FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.subscription_plans TO authenticated;

CREATE POLICY subscription_plans_public_read
ON public.subscription_plans
FOR SELECT TO authenticated
USING (status='active' AND is_public);

INSERT INTO public.subscription_plans(code,display_name,description,tier_rank,status,is_public)
VALUES
  ('starter','Starter','Plan base para organizaciones pequeñas que comienzan a operar con StOmni.',100,'active',true),
  ('business','Business','Plan para organizaciones con operación comercial y estructura empresarial en crecimiento.',200,'active',true),
  ('pro','Pro','Plan avanzado para organizaciones que requieren mayor capacidad operativa y analítica.',300,'active',true),
  ('enterprise','Enterprise','Plan de mayor escala para organizaciones con necesidades empresariales avanzadas.',400,'active',true)
ON CONFLICT (code) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  tier_rank=EXCLUDED.tier_rank;

CREATE OR REPLACE FUNCTION public.list_subscription_plans_v1()
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
  SELECT jsonb_build_object(
    'id',p.id,
    'code',p.code,
    'display_name',p.display_name,
    'description',p.description,
    'tier_rank',p.tier_rank
  )
  FROM public.subscription_plans p
  WHERE p.status='active' AND p.is_public
  ORDER BY p.tier_rank,p.code;
$$;

REVOKE ALL ON FUNCTION public.list_subscription_plans_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_subscription_plans_v1() TO authenticated;

-- Defensa: ningún cliente de tenant puede administrar el catálogo global.
REVOKE INSERT,UPDATE,DELETE ON TABLE public.subscription_plans FROM authenticated;

COMMIT;
