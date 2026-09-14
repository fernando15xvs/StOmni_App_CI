import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.49.4'
import {
  AuthGuardError,
  requireEmployee,
} from '../_shared/auth_guard.ts'
import { serveObserved } from '../_shared/observability.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    },
  })
}

async function hasRows(
  admin: SupabaseClient,
  table: string,
  column: string,
  value: string | number,
): Promise<boolean> {
  const { count, error } = await admin
    .from(table)
    .select('*', { count: 'exact', head: true })
    .eq(column, value)

  if (error) {
    // Fail-closed: si no puede comprobarse el historial, no se elimina.
    throw new Error(`No se pudo verificar historial en ${table}: ${error.message}`)
  }
  return (count ?? 0) > 0
}

serve(serveObserved('delete_employee', async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') {
    return jsonResponse({ success: false, error: 'Método no permitido' }, 405)
  }

  try {
    const context = await requireEmployee(req, ['admin'])
    const body = await req.json().catch(() => ({}))
    const empleadoId = Number(body?.empleado_id)
    if (!Number.isInteger(empleadoId) || empleadoId <= 0) {
      return jsonResponse({ success: false, error: 'empleado_id inválido' }, 400)
    }

    // context.admin ya filtra empleados por organization_id. Un id conocido de
    // otro tenant se comporta como inexistente y no revela información.
    const { data: target, error: targetError } = await context.admin
      .from('empleados')
      .select('id, app_user_id, auth_id, activo')
      .eq('id', empleadoId)
      .maybeSingle()
    if (targetError) throw targetError
    if (!target) {
      return jsonResponse({ success: false, error: 'El empleado no existe' }, 404)
    }

    const targetAccessId = String(
      target.app_user_id ?? target.auth_id ?? '',
    ).trim()

    if (targetAccessId && targetAccessId === context.user.id) {
      return jsonResponse({ success: false, error: 'No puedes eliminarte a ti mismo' }, 409)
    }

    // app_users/base_role es la autoridad de acceso. app_users no usa el wrapper
    // automático de tablas operativas, por lo que el tenant se filtra explícito.
    let targetMembership: {
      user_id: string
      base_role: string
      status: string
    } | null = null

    if (targetAccessId) {
      const { data: membership, error: membershipError } = await context.admin
        .from('app_users')
        .select('user_id, base_role, status')
        .eq('organization_id', context.organizationId)
        .eq('user_id', targetAccessId)
        .maybeSingle()

      if (membershipError) throw membershipError
      targetMembership = membership

      if (
        targetMembership?.base_role === 'admin' &&
        targetMembership.status === 'active'
      ) {
        const { count, error } = await context.admin
          .from('app_users')
          .select('*', { count: 'exact', head: true })
          .eq('organization_id', context.organizationId)
          .eq('base_role', 'admin')
          .eq('status', 'active')
        if (error) throw error
        if ((count ?? 0) <= 1) {
          return jsonResponse({
            success: false,
            error: 'No puedes eliminar al único administrador activo de la organización',
          }, 409)
        }
      }
    }

    // No elimina identidades con historial. Los campos bigint usan empleados.id
    // y los snapshots tributarios UUID usan la identidad Auth/app_user canónica.
    const employeeIdReferences = [
      ['ventas', 'vendedor_id', 'ventas'],
      ['ventas', 'descuento_autorizado_por', 'autorizaciones de descuento'],
      ['constancias_descuento', 'aplicado_por', 'constancias de descuento'],
      ['constancias_descuento', 'autorizado_por', 'autorizaciones de descuento'],
    ] as const

    for (const [table, column, label] of employeeIdReferences) {
      if (await hasRows(context.admin, table, column, empleadoId)) {
        return jsonResponse({
          success: false,
          error: 'historical_records_exist',
          message: `El empleado tiene ${label} asociadas. Utilice Dar de baja.`,
        }, 409)
      }
    }

    if (targetAccessId) {
      const uuidReferences = [
        ['notas_credito', 'creado_por'],
        ['guias_remision', 'creado_por'],
        ['procesos_tributarios', 'creado_por'],
        ['solicitudes_baja_tributaria', 'creado_por'],
      ] as const

      for (const [table, column] of uuidReferences) {
        if (await hasRows(context.admin, table, column, targetAccessId)) {
          return jsonResponse({
            success: false,
            error: 'historical_records_exist',
            message:
              'El empleado tiene historial tributario asociado. Utilice Dar de baja.',
          }, 409)
        }
      }
    }

    // Cortar primero el acceso canónico. Si una operación posterior falla, el
    // usuario queda sin acceso operativo aunque la ficha laboral aún exista.
    if (targetMembership) {
      const { error: disableMembershipError } = await context.admin
        .from('app_users')
        .update({ status: 'disabled' })
        .eq('organization_id', context.organizationId)
        .eq('user_id', targetAccessId)
      if (disableMembershipError) throw disableMembershipError
    }

    const { error: disableEmployeeError } = await context.admin
      .from('empleados')
      .update({ activo: false })
      .eq('id', empleadoId)
    if (disableEmployeeError) throw disableEmployeeError

    // La ficha se elimina antes de app_users porque empleados mantiene una FK
    // RESTRICT hacia la membresía canónica.
    const { error: deleteDataError } = await context.admin
      .from('empleados')
      .delete()
      .eq('id', empleadoId)
    if (deleteDataError) {
      throw new Error(
        'El acceso fue deshabilitado, pero no se pudo borrar la ficha del empleado. '
          + `Utilice la baja lógica: ${deleteDataError.message}`,
      )
    }

    if (targetMembership) {
      const { error: deleteMembershipError } = await context.admin
        .from('app_users')
        .delete()
        .eq('organization_id', context.organizationId)
        .eq('user_id', targetAccessId)
      if (deleteMembershipError) {
        throw new Error(
          'La ficha fue eliminada y el acceso quedó deshabilitado, pero no se pudo eliminar la membresía. '
            + `Revise app_users antes de reintentar: ${deleteMembershipError.message}`,
        )
      }
    }

    // Auth se elimina al final. Si falla, la identidad global queda huérfana pero
    // no puede entrar a StOmni porque ya no conserva app_users activo.
    if (targetAccessId) {
      const { error: deleteAuthError } =
        await context.admin.auth.admin.deleteUser(targetAccessId)
      if (deleteAuthError && !deleteAuthError.message.includes('User not found')) {
        throw new Error(`No se pudo borrar el acceso Auth: ${deleteAuthError.message}`)
      }
    }

    return jsonResponse({
      success: true,
      message: 'Empleado eliminado definitivamente',
    })
  } catch (error) {
    const status = error instanceof AuthGuardError ? error.status : 400
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    }, status)
  }
}))