-- Fase 7.3: entitlements y límites por plan.
-- Los valores iniciales son neutrales/full-access para no inventar packaging comercial.
-- El esquema queda preparado para que una configuración privilegiada cambie valores sin migración.
BEGIN;

CREATE TABLE public.entitlement_definitions (
  key text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_.]{2,63}$'),
  kind text NOT NULL CHECK (kind IN ('feature','limit')),
  description text NOT NULL DEFAULT '' CHECK (length(description) <= 300),
  unit text CHECK (unit IS NULL OR unit IN ('count')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.plan_entitlements (
  plan_id uuid NOT NULL REFERENCES public.subscription_plans(id) ON DELETE CASCADE,
  entitlement_key text NOT NULL REFERENCES public.entitlement_definitions(key) ON DELETE RESTRICT,
  enabled boolean NOT NULL DEFAULT true,
  limit_value bigint,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(plan_id,entitlement_key),
  CHECK (limit_value IS NULL OR limit_value >= 0)
);

ALTER TABLE public.entitlement_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_entitlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.entitlement_definitions,public.plan_entitlements FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.entitlement_definitions,public.plan_entitlements TO authenticated;

CREATE POLICY entitlement_definitions_read
ON public.entitlement_definitions FOR SELECT TO authenticated USING (true);
CREATE POLICY plan_entitlements_public_plan_read
ON public.plan_entitlements FOR SELECT TO authenticated
USING (EXISTS(
  SELECT 1 FROM public.subscription_plans p
  WHERE p.id=plan_id AND p.status='active' AND p.is_public
));

INSERT INTO public.entitlement_definitions(key,kind,description,unit) VALUES
  ('feature.inventory','feature','Módulo de inventario',NULL),
  ('feature.multiple_branches','feature','Múltiples sucursales',NULL),
  ('feature.multiple_warehouses','feature','Múltiples almacenes',NULL),
  ('feature.credit_sales','feature','Ventas al crédito',NULL),
  ('feature.electronic_invoicing','feature','Facturación electrónica',NULL),
  ('feature.purchase_management','feature','Gestión de compras',NULL),
  ('feature.services','feature','Servicios no inventariables',NULL),
  ('feature.variants','feature','Variantes de producto',NULL),
  ('feature.lot_tracking','feature','Trazabilidad por lotes',NULL),
  ('feature.serial_tracking','feature','Trazabilidad por series',NULL),
  ('feature.analytics','feature','Dashboard/analítica avanzada',NULL),
  ('feature.business_assistant','feature','Asistente empresarial',NULL),
  ('limit.users','limit','Usuarios activos máximos','count'),
  ('limit.branches','limit','Sucursales activas máximas','count'),
  ('limit.warehouses','limit','Almacenes activos máximos','count'),
  ('limit.cash_registers','limit','Cajas activas máximas','count')
ON CONFLICT (key) DO NOTHING;

-- Seed neutral: todas las features habilitadas y límites NULL = sin límite configurado.
INSERT INTO public.plan_entitlements(plan_id,entitlement_key,enabled,limit_value)
SELECT p.id,d.key,true,NULL
FROM public.subscription_plans p
CROSS JOIN public.entitlement_definitions d
WHERE p.code IN ('starter','business','pro','enterprise')
ON CONFLICT (plan_id,entitlement_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_my_entitlements_v1()
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_org uuid:=private.require_current_organization_id();
BEGIN
  RETURN QUERY
  SELECT jsonb_build_object(
    'key',d.key,
    'kind',d.kind,
    'enabled',e.enabled,
    'limit_value',e.limit_value,
    'unit',d.unit
  )
  FROM public.organization_subscriptions s
  JOIN public.plan_entitlements e ON e.plan_id=s.plan_id
  JOIN public.entitlement_definitions d ON d.key=e.entitlement_key
  WHERE s.organization_id=v_org
  ORDER BY d.key;
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_entitlements_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_my_entitlements_v1() TO authenticated;

CREATE OR REPLACE FUNCTION private.subscription_feature_enabled(
  p_organization_id uuid,p_key text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
 SELECT COALESCE((
   SELECT e.enabled
   FROM public.organization_subscriptions s
   JOIN public.plan_entitlements e ON e.plan_id=s.plan_id
   JOIN public.entitlement_definitions d ON d.key=e.entitlement_key
   WHERE s.organization_id=p_organization_id AND d.key=p_key AND d.kind='feature'
     AND s.status IN ('active','trialing')
 ),false);
$$;

CREATE OR REPLACE FUNCTION private.subscription_limit_value(
  p_organization_id uuid,p_key text
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
 SELECT (
   SELECT CASE WHEN e.enabled THEN e.limit_value ELSE 0 END
   FROM public.organization_subscriptions s
   JOIN public.plan_entitlements e ON e.plan_id=s.plan_id
   JOIN public.entitlement_definitions d ON d.key=e.entitlement_key
   WHERE s.organization_id=p_organization_id AND d.key=p_key AND d.kind='limit'
     AND s.status IN ('active','trialing')
 );
$$;

REVOKE ALL ON FUNCTION private.subscription_feature_enabled(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.subscription_limit_value(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.subscription_feature_enabled(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION private.subscription_limit_value(uuid,text) TO service_role;

CREATE OR REPLACE FUNCTION private.set_plan_entitlement_v1(
  p_plan_code text,p_entitlement_key text,p_enabled boolean,p_limit_value bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE v_plan uuid; v_kind text;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Privileged entitlement writer required';
  END IF;
  SELECT id INTO v_plan FROM public.subscription_plans WHERE code=p_plan_code;
  SELECT kind INTO v_kind FROM public.entitlement_definitions WHERE key=p_entitlement_key;
  IF v_plan IS NULL OR v_kind IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unknown plan or entitlement'; END IF;
  IF v_kind='feature' AND p_limit_value IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Feature entitlement cannot have limit_value'; END IF;
  IF v_kind='limit' AND p_limit_value IS NOT NULL AND p_limit_value<0 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Limit cannot be negative'; END IF;
  INSERT INTO public.plan_entitlements(plan_id,entitlement_key,enabled,limit_value,updated_at)
  VALUES(v_plan,p_entitlement_key,COALESCE(p_enabled,false),p_limit_value,now())
  ON CONFLICT(plan_id,entitlement_key) DO UPDATE
    SET enabled=EXCLUDED.enabled,limit_value=EXCLUDED.limit_value,updated_at=now();
END;
$$;
REVOKE ALL ON FUNCTION private.set_plan_entitlement_v1(text,text,boolean,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.set_plan_entitlement_v1(text,text,boolean,bigint) TO service_role;

COMMIT;
