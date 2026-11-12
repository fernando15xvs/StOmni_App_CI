-- 2D-I2 preparation ONLY: no second membership is possible yet.
-- Indexes for future tenant-scoped user/employee identity.
-- Keep app_users_pkey(user_id) and empleados_app_user_id_key in place until
-- bootstrap, signup state, audit attribution, edge functions and Flutter
-- client selection are fully migrated and certified.
CREATE INDEX IF NOT EXISTS app_users_identity_selection_idx
  ON public.app_users(user_id,status,organization_id);

CREATE UNIQUE INDEX IF NOT EXISTS empleados_organization_app_user_ready_uidx
  ON public.empleados(organization_id,app_user_id)
  WHERE app_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS empleados_organization_auth_lookup_idx
  ON public.empleados(organization_id,auth_id)
  WHERE auth_id IS NOT NULL;
