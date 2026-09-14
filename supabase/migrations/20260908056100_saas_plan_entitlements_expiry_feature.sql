-- Corrección F7.3: expiry_tracking es capability independiente y requiere entitlement propio.
BEGIN;

INSERT INTO public.entitlement_definitions(key,kind,description,unit)
VALUES('feature.expiry_tracking','feature','Control de vencimientos sobre lotes',NULL)
ON CONFLICT(key) DO NOTHING;

INSERT INTO public.plan_entitlements(plan_id,entitlement_key,enabled,limit_value)
SELECT p.id,'feature.expiry_tracking',true,NULL
FROM public.subscription_plans p
ON CONFLICT(plan_id,entitlement_key) DO NOTHING;

COMMIT;
