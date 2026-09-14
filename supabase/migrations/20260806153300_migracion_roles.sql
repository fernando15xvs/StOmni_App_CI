BEGIN;

-- 1. Eliminar temporalmente la restricción antigua.
ALTER TABLE public.empleados
DROP CONSTRAINT IF EXISTS empleados_rol_check;

-- 2. Normalizar posibles valores antiguos.
UPDATE public.empleados
SET rol = CASE
  WHEN lower(trim(rol)) IN ('admin', 'administrador')
    THEN 'admin'

  WHEN lower(trim(rol)) IN (
    'vendedor',
    'almacenero',
    'operador',
    'operador de ventas y almacén',
    'operador de ventas y almacen'
  )
    THEN 'operador'

  ELSE lower(trim(rol))
END
WHERE rol IS NOT NULL;

-- 3. Detener la migración si existe algún valor desconocido.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.empleados
    WHERE rol IS NULL
       OR trim(rol) = ''
       OR lower(trim(rol)) NOT IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION
      'Existen empleados con roles desconocidos. Revisa public.empleados antes de continuar.';
  END IF;
END;
$$;

-- 4. Configuración definitiva de la columna.
ALTER TABLE public.empleados
  ALTER COLUMN rol SET DEFAULT 'operador',
  ALTER COLUMN rol SET NOT NULL;

ALTER TABLE public.empleados
ADD CONSTRAINT empleados_rol_check
CHECK (rol IN ('admin', 'operador'));

-- 5. Empleado activo: solo admite los dos roles oficiales.
CREATE OR REPLACE FUNCTION public.app_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$function$;

-- 6. Administrador: solo el valor técnico admin.
CREATE OR REPLACE FUNCTION public.app_es_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  );
$function$;

-- 7. Catálogos GRE: administrador u operador activo.
CREATE OR REPLACE FUNCTION public._gre_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$function$;

-- 8. Simplificar la política de intentos de facturación.
DROP POLICY IF EXISTS intentos_select_supervisor
ON public.facturacion_intentos;

CREATE POLICY intentos_select_admin
ON public.facturacion_intentos
FOR SELECT
TO authenticated
USING (public.app_es_admin());

COMMIT;
