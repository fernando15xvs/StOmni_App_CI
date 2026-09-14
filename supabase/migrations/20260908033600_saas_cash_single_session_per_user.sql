-- Fase 4.3: mientras los entrypoints cash actuales derivan la sesión desde auth.uid(),
-- una misma cuenta no puede operar dos cajas abiertas simultáneamente.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.sesiones_caja
    WHERE estado='ABIERTA'
    GROUP BY organization_id,usuario_id
    HAVING count(*)>1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE='23514',
      MESSAGE='Ambiguous state: a user has multiple open cash sessions in one organization';
  END IF;
END;
$guard$;

CREATE UNIQUE INDEX sesiones_caja_one_open_per_user_key
  ON public.sesiones_caja(organization_id,usuario_id)
  WHERE estado='ABIERTA';

COMMIT;
