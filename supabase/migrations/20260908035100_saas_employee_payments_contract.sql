-- Fase 4.4: contract final de pagos de personal.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.pagos_empleados WHERE empleado_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee payment without employee_id cannot be contracted';
  END IF;
END;
$guard$;

ALTER TABLE public.pagos_empleados
  ALTER COLUMN empleado_id SET NOT NULL;

COMMIT;
