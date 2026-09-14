-- Fase 4.5: eliminar ambigüedad de scope en policy de overrides.
BEGIN;

DROP POLICY IF EXISTS employee_permission_tenant_read ON public.employee_permission_overrides;
CREATE POLICY employee_permission_tenant_read ON public.employee_permission_overrides
FOR SELECT TO authenticated
USING(
  private.row_belongs_to_current_organization(employee_permission_overrides.organization_id)
  AND (
    private.has_permission('tenant.admin')
    OR employee_permission_overrides.employee_id=(
      SELECT e.id
      FROM public.empleados e
      WHERE e.organization_id=employee_permission_overrides.organization_id
        AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
      LIMIT 1
    )
  )
);

COMMIT;
