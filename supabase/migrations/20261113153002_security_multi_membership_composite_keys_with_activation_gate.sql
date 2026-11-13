-- I2: tenant-composite membership keys, with multiple memberships
-- deliberately DISABLED until I3 and I4 are certified.
-- The atomic tenant+role resolver and active-employment guard remain in force.
CREATE OR REPLACE FUNCTION private.enforce_single_membership_until_i4()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $gate$
BEGIN
  -- Lock the Auth row to serialize competing requests for the same user.
  PERFORM 1 FROM auth.users u WHERE u.id=NEW.user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='23503',
      MESSAGE='Membership requires an existing authentication identity';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.app_users a
    WHERE a.user_id=NEW.user_id AND a.organization_id<>NEW.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23505',
      MESSAGE='Multi-organization memberships are not activated';
  END IF;
  RETURN NEW;
END;
$gate$;
REVOKE ALL ON FUNCTION private.enforce_single_membership_until_i4()
  FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS app_users_multi_membership_activation_gate ON public.app_users;
CREATE TRIGGER app_users_multi_membership_activation_gate
BEFORE INSERT ON public.app_users FOR EACH ROW
EXECUTE FUNCTION private.enforce_single_membership_until_i4();

-- Preserve the separate composite UNIQUE used by the existing employee FK.
ALTER TABLE public.app_users DROP CONSTRAINT app_users_pkey;
ALTER TABLE public.app_users ADD CONSTRAINT app_users_pkey
  PRIMARY KEY (organization_id,user_id);

ALTER TABLE public.empleados DROP CONSTRAINT empleados_app_user_id_key;
ALTER TABLE public.empleados ADD CONSTRAINT empleados_organization_app_user_key
  UNIQUE (organization_id,app_user_id);
