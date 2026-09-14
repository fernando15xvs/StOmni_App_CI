-- Fase 7.4: enforcement backend de entitlements/límites.
BEGIN;

CREATE OR REPLACE FUNCTION private.subscription_access_allowed(p_organization_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.organization_subscriptions s
    WHERE s.organization_id=p_organization_id
      AND s.status IN ('active','trialing')
  );
$$;
REVOKE ALL ON FUNCTION private.subscription_access_allowed(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.plan_feature_enabled(p_plan_id uuid,p_key text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $$
  SELECT COALESCE((
    SELECT e.enabled
    FROM public.plan_entitlements e
    JOIN public.entitlement_definitions d ON d.key=e.entitlement_key
    WHERE e.plan_id=p_plan_id AND e.entitlement_key=p_key AND d.kind='feature'
  ),false);
$$;
REVOKE ALL ON FUNCTION private.plan_feature_enabled(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.plan_limit_value(p_plan_id uuid,p_key text)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $$
  SELECT (
    SELECT CASE WHEN e.enabled THEN e.limit_value ELSE 0 END
    FROM public.plan_entitlements e
    JOIN public.entitlement_definitions d ON d.key=e.entitlement_key
    WHERE e.plan_id=p_plan_id AND e.entitlement_key=p_key AND d.kind='limit'
  );
$$;
REVOKE ALL ON FUNCTION private.plan_limit_value(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.require_subscription_feature_for_org(
  p_organization_id uuid,p_key text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
BEGIN
  IF NOT private.subscription_access_allowed(p_organization_id) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='An active or trialing subscription is required';
  END IF;
  IF NOT private.subscription_feature_enabled(p_organization_id,p_key) THEN
    RAISE EXCEPTION 'Subscription feature unavailable: %',p_key USING ERRCODE='42501';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.require_subscription_feature_for_org(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.assert_plan_compatible_with_organization(
  p_organization_id uuid,p_plan_id uuid
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  c public.business_capabilities%ROWTYPE;
  v_limit bigint;
BEGIN
  SELECT * INTO c FROM public.business_capabilities WHERE organization_id=p_organization_id;
  IF FOUND THEN
    IF c.inventory_enabled AND NOT private.plan_feature_enabled(p_plan_id,'feature.inventory') THEN RAISE EXCEPTION 'Plan does not allow inventory' USING ERRCODE='23514'; END IF;
    IF c.multiple_branches AND NOT private.plan_feature_enabled(p_plan_id,'feature.multiple_branches') THEN RAISE EXCEPTION 'Plan does not allow multiple branches' USING ERRCODE='23514'; END IF;
    IF c.multiple_warehouses AND NOT private.plan_feature_enabled(p_plan_id,'feature.multiple_warehouses') THEN RAISE EXCEPTION 'Plan does not allow multiple warehouses' USING ERRCODE='23514'; END IF;
    IF c.credit_sales AND NOT private.plan_feature_enabled(p_plan_id,'feature.credit_sales') THEN RAISE EXCEPTION 'Plan does not allow credit sales' USING ERRCODE='23514'; END IF;
    IF c.electronic_invoicing AND NOT private.plan_feature_enabled(p_plan_id,'feature.electronic_invoicing') THEN RAISE EXCEPTION 'Plan does not allow electronic invoicing' USING ERRCODE='23514'; END IF;
    IF c.purchase_management AND NOT private.plan_feature_enabled(p_plan_id,'feature.purchase_management') THEN RAISE EXCEPTION 'Plan does not allow purchases' USING ERRCODE='23514'; END IF;
    IF c.services AND NOT private.plan_feature_enabled(p_plan_id,'feature.services') THEN RAISE EXCEPTION 'Plan does not allow services' USING ERRCODE='23514'; END IF;
    IF c.variants AND NOT private.plan_feature_enabled(p_plan_id,'feature.variants') THEN RAISE EXCEPTION 'Plan does not allow variants' USING ERRCODE='23514'; END IF;
    IF c.lot_tracking AND NOT private.plan_feature_enabled(p_plan_id,'feature.lot_tracking') THEN RAISE EXCEPTION 'Plan does not allow lot tracking' USING ERRCODE='23514'; END IF;
    IF c.expiry_tracking AND NOT private.plan_feature_enabled(p_plan_id,'feature.expiry_tracking') THEN RAISE EXCEPTION 'Plan does not allow expiry tracking' USING ERRCODE='23514'; END IF;
    IF c.serial_number_tracking AND NOT private.plan_feature_enabled(p_plan_id,'feature.serial_tracking') THEN RAISE EXCEPTION 'Plan does not allow serial tracking' USING ERRCODE='23514'; END IF;
  END IF;

  v_limit:=private.plan_limit_value(p_plan_id,'limit.users');
  IF v_limit IS NOT NULL AND (SELECT count(*) FROM public.app_users u WHERE u.organization_id=p_organization_id AND u.status='active')>v_limit THEN
    RAISE EXCEPTION 'Plan user limit is below current active usage' USING ERRCODE='23514';
  END IF;
  v_limit:=private.plan_limit_value(p_plan_id,'limit.branches');
  IF v_limit IS NOT NULL AND (SELECT count(*) FROM public.branches b WHERE b.organization_id=p_organization_id AND b.status='active')>v_limit THEN
    RAISE EXCEPTION 'Plan branch limit is below current active usage' USING ERRCODE='23514';
  END IF;
  v_limit:=private.plan_limit_value(p_plan_id,'limit.warehouses');
  IF v_limit IS NOT NULL AND (SELECT count(*) FROM public.almacenes a WHERE a.organization_id=p_organization_id AND COALESCE(a.activo,true))>v_limit THEN
    RAISE EXCEPTION 'Plan warehouse limit is below current active usage' USING ERRCODE='23514';
  END IF;
  v_limit:=private.plan_limit_value(p_plan_id,'limit.cash_registers');
  IF v_limit IS NOT NULL AND (SELECT count(*) FROM public.cash_registers r WHERE r.organization_id=p_organization_id AND r.status='active')>v_limit THEN
    RAISE EXCEPTION 'Plan cash register limit is below current active usage' USING ERRCODE='23514';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.assert_plan_compatible_with_organization(uuid,uuid) FROM PUBLIC,anon,authenticated;

-- Capabilities funcionales nunca pueden superar lo permitido por el plan.
CREATE OR REPLACE FUNCTION private.enforce_subscription_business_capabilities()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_plan uuid;
BEGIN
  SELECT s.plan_id INTO v_plan FROM public.organization_subscriptions s
  WHERE s.organization_id=NEW.organization_id AND s.status IN ('active','trialing');
  IF v_plan IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Usable subscription required for business capabilities'; END IF;
  IF NEW.inventory_enabled AND NOT private.plan_feature_enabled(v_plan,'feature.inventory') THEN RAISE EXCEPTION 'Plan blocks inventory' USING ERRCODE='42501'; END IF;
  IF NEW.multiple_branches AND NOT private.plan_feature_enabled(v_plan,'feature.multiple_branches') THEN RAISE EXCEPTION 'Plan blocks multiple branches' USING ERRCODE='42501'; END IF;
  IF NEW.multiple_warehouses AND NOT private.plan_feature_enabled(v_plan,'feature.multiple_warehouses') THEN RAISE EXCEPTION 'Plan blocks multiple warehouses' USING ERRCODE='42501'; END IF;
  IF NEW.credit_sales AND NOT private.plan_feature_enabled(v_plan,'feature.credit_sales') THEN RAISE EXCEPTION 'Plan blocks credit sales' USING ERRCODE='42501'; END IF;
  IF NEW.electronic_invoicing AND NOT private.plan_feature_enabled(v_plan,'feature.electronic_invoicing') THEN RAISE EXCEPTION 'Plan blocks electronic invoicing' USING ERRCODE='42501'; END IF;
  IF NEW.purchase_management AND NOT private.plan_feature_enabled(v_plan,'feature.purchase_management') THEN RAISE EXCEPTION 'Plan blocks purchase management' USING ERRCODE='42501'; END IF;
  IF NEW.services AND NOT private.plan_feature_enabled(v_plan,'feature.services') THEN RAISE EXCEPTION 'Plan blocks services' USING ERRCODE='42501'; END IF;
  IF NEW.variants AND NOT private.plan_feature_enabled(v_plan,'feature.variants') THEN RAISE EXCEPTION 'Plan blocks variants' USING ERRCODE='42501'; END IF;
  IF NEW.lot_tracking AND NOT private.plan_feature_enabled(v_plan,'feature.lot_tracking') THEN RAISE EXCEPTION 'Plan blocks lot tracking' USING ERRCODE='42501'; END IF;
  IF NEW.expiry_tracking AND NOT private.plan_feature_enabled(v_plan,'feature.expiry_tracking') THEN RAISE EXCEPTION 'Plan blocks expiry tracking' USING ERRCODE='42501'; END IF;
  IF NEW.serial_number_tracking AND NOT private.plan_feature_enabled(v_plan,'feature.serial_tracking') THEN RAISE EXCEPTION 'Plan blocks serial tracking' USING ERRCODE='42501'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_subscription_business_capabilities() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS zz_business_capabilities_subscription_guard ON public.business_capabilities;
CREATE TRIGGER zz_business_capabilities_subscription_guard
BEFORE INSERT OR UPDATE ON public.business_capabilities
FOR EACH ROW EXECUTE FUNCTION private.enforce_subscription_business_capabilities();

CREATE OR REPLACE FUNCTION private.enforce_subscription_count_limit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_org uuid;
  v_key text;
  v_active boolean;
  v_was_active boolean:=false;
  v_limit bigint;
  v_count bigint;
BEGIN
  IF TG_TABLE_NAME='app_users' THEN
    v_org:=NEW.organization_id; v_key:='limit.users'; v_active:=NEW.status='active';
    IF TG_OP='UPDATE' THEN v_was_active:=OLD.status='active'; END IF;
    IF v_active AND NOT v_was_active THEN SELECT count(*) INTO v_count FROM public.app_users x WHERE x.organization_id=v_org AND x.status='active' AND x.user_id<>NEW.user_id; END IF;
  ELSIF TG_TABLE_NAME='branches' THEN
    v_org:=NEW.organization_id; v_key:='limit.branches'; v_active:=NEW.status='active';
    IF TG_OP='UPDATE' THEN v_was_active:=OLD.status='active'; END IF;
    IF v_active AND NOT v_was_active THEN SELECT count(*) INTO v_count FROM public.branches x WHERE x.organization_id=v_org AND x.status='active' AND x.id<>NEW.id; END IF;
  ELSIF TG_TABLE_NAME='almacenes' THEN
    v_org:=NEW.organization_id; v_key:='limit.warehouses'; v_active:=COALESCE(NEW.activo,true);
    IF TG_OP='UPDATE' THEN v_was_active:=COALESCE(OLD.activo,true); END IF;
    IF v_active AND NOT v_was_active THEN SELECT count(*) INTO v_count FROM public.almacenes x WHERE x.organization_id=v_org AND COALESCE(x.activo,true) AND x.id<>NEW.id; END IF;
  ELSIF TG_TABLE_NAME='cash_registers' THEN
    v_org:=NEW.organization_id; v_key:='limit.cash_registers'; v_active:=NEW.status='active';
    IF TG_OP='UPDATE' THEN v_was_active:=OLD.status='active'; END IF;
    IF v_active AND NOT v_was_active THEN SELECT count(*) INTO v_count FROM public.cash_registers x WHERE x.organization_id=v_org AND x.status='active' AND x.id<>NEW.id; END IF;
  ELSE
    RETURN NEW;
  END IF;

  IF NOT v_active OR v_was_active THEN RETURN NEW; END IF;
  IF NOT private.subscription_access_allowed(v_org) THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Usable subscription required'; END IF;
  v_limit:=private.subscription_limit_value(v_org,v_key);
  IF v_limit IS NOT NULL AND COALESCE(v_count,0)+1>v_limit THEN
    RAISE EXCEPTION 'Subscription limit exceeded: %',v_key USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_subscription_count_limit() FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS zz_app_users_subscription_limit ON public.app_users;
CREATE TRIGGER zz_app_users_subscription_limit BEFORE INSERT OR UPDATE ON public.app_users FOR EACH ROW EXECUTE FUNCTION private.enforce_subscription_count_limit();
DROP TRIGGER IF EXISTS zz_branches_subscription_limit ON public.branches;
CREATE TRIGGER zz_branches_subscription_limit BEFORE INSERT OR UPDATE ON public.branches FOR EACH ROW EXECUTE FUNCTION private.enforce_subscription_count_limit();
DROP TRIGGER IF EXISTS zz_almacenes_subscription_limit ON public.almacenes;
CREATE TRIGGER zz_almacenes_subscription_limit BEFORE INSERT OR UPDATE ON public.almacenes FOR EACH ROW EXECUTE FUNCTION private.enforce_subscription_count_limit();
DROP TRIGGER IF EXISTS zz_cash_registers_subscription_limit ON public.cash_registers;
CREATE TRIGGER zz_cash_registers_subscription_limit BEFORE INSERT OR UPDATE ON public.cash_registers FOR EACH ROW EXECUTE FUNCTION private.enforce_subscription_count_limit();

-- Downgrade/change de plan: nunca deja al tenant en un estado que el nuevo plan no soporta.
CREATE OR REPLACE FUNCTION private.set_organization_subscription_v1(
  p_organization_id uuid,p_plan_code text,p_status text,p_assignment_reason text,
  p_expected_revision bigint,p_period_start timestamptz DEFAULT NULL,
  p_period_end timestamptz DEFAULT NULL,p_cancel_at_period_end boolean DEFAULT false
)
RETURNS public.organization_subscriptions
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_plan uuid; v_row public.organization_subscriptions;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Privileged subscription writer required'; END IF;
  SELECT id INTO v_plan FROM public.subscription_plans WHERE code=p_plan_code AND status='active';
  IF v_plan IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unknown active plan'; END IF;
  IF p_status NOT IN ('trialing','active','past_due','suspended','canceled') THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid subscription status'; END IF;
  IF p_assignment_reason NOT IN ('legacy_grandfathered','bootstrap_default','admin_override','billing_sync') THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid assignment reason'; END IF;
  IF p_status IN ('active','trialing') THEN PERFORM private.assert_plan_compatible_with_organization(p_organization_id,v_plan); END IF;
  UPDATE public.organization_subscriptions s
  SET plan_id=v_plan,status=p_status,assignment_reason=p_assignment_reason,
      current_period_start=p_period_start,current_period_end=p_period_end,
      cancel_at_period_end=COALESCE(p_cancel_at_period_end,false),revision=s.revision+1,updated_at=now()
  WHERE s.organization_id=p_organization_id AND s.revision=p_expected_revision
  RETURNING s.* INTO v_row;
  IF v_row.organization_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='Subscription revision conflict or organization not found'; END IF;
  RETURN v_row;
END;
$$;

-- Cambiar packaging tampoco puede invalidar tenants ya asignados al plan.
CREATE OR REPLACE FUNCTION private.set_plan_entitlement_v1(
  p_plan_code text,p_entitlement_key text,p_enabled boolean,p_limit_value bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_plan uuid; v_kind text; v_org uuid;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Privileged entitlement writer required'; END IF;
  SELECT id INTO v_plan FROM public.subscription_plans WHERE code=p_plan_code;
  SELECT kind INTO v_kind FROM public.entitlement_definitions WHERE key=p_entitlement_key;
  IF v_plan IS NULL OR v_kind IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unknown plan or entitlement'; END IF;
  IF v_kind='feature' AND p_limit_value IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Feature entitlement cannot have limit_value'; END IF;
  IF v_kind='limit' AND p_limit_value IS NOT NULL AND p_limit_value<0 THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Limit cannot be negative'; END IF;
  INSERT INTO public.plan_entitlements(plan_id,entitlement_key,enabled,limit_value,updated_at)
  VALUES(v_plan,p_entitlement_key,COALESCE(p_enabled,false),p_limit_value,now())
  ON CONFLICT(plan_id,entitlement_key) DO UPDATE SET enabled=EXCLUDED.enabled,limit_value=EXCLUDED.limit_value,updated_at=now();
  FOR v_org IN SELECT s.organization_id FROM public.organization_subscriptions s WHERE s.plan_id=v_plan AND s.status IN ('active','trialing') LOOP
    PERFORM private.assert_plan_compatible_with_organization(v_org,v_plan);
  END LOOP;
END;
$$;

COMMIT;
