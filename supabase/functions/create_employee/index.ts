import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
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

function safeDiagnostic(code: string): void {
  console.warn(JSON.stringify({
    kind: 'stomni_internal',
    component: 'create_employee',
    error_code: code,
  }))
}

function cleanOptional(value: unknown): string | null {
  const text = String(value ?? '').trim()
  return text.length === 0 ? null : text
}

function validRole(value: unknown): 'admin' | 'operador' | null {
  const role = String(value ?? '').trim().toLowerCase()
  if (role === 'admin' || role === 'operador') return role
  return null
}

async function deleteAuthBestEffort(
  admin: Awaited<ReturnType<typeof requireEmployee>>['admin'],
  authId: string,
): Promise<void> {
  const { error } = await admin.auth.admin.deleteUser(authId)
  if (error && !error.message.includes('User not found')) {
    safeDiagnostic('AUTH_COMPENSATION_FAILED')
  }
}

async function rollbackAccessBestEffort(
  admin: Awaited<ReturnType<typeof requireEmployee>>['admin'],
  organizationId: string,
  authId: string,
): Promise<void> {
  // Fail-closed incluso si una FK impide borrar la membresía porque la ficha
  // llegó a enlazarse antes de un error de verificación.
  const { error: disableError } = await admin
    .from('app_users')
    .update({ status: 'disabled' })
    .eq('organization_id', organizationId)
    .eq('user_id', authId)

  if (disableError) {
    safeDiagnostic('MEMBERSHIP_DISABLE_COMPENSATION_FAILED')
  }

  const { error: membershipError } = await admin
    .from('app_users')
    .delete()
    .eq('organization_id', organizationId)
    .eq('user_id', authId)

  if (membershipError) {
    safeDiagnostic('MEMBERSHIP_DELETE_COMPENSATION_FAILED')
  }

  await deleteAuthBestEffort(admin, authId)
}

serve(serveObserved('create_employee', async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') {
    return jsonResponse({ success: false, error: 'Método no permitido' }, 405)
  }

  try {
    const context = await requireEmployee(req, ['admin'])
    const body = await req.json().catch(() => ({}))

    const email = String(body?.email ?? '').trim().toLowerCase()
    const nombre = String(body?.nombre ?? '').trim()
    let password = String(body?.password ?? '').trim()
    const empleadoData = body?.empleado_data
    const empleadoId = Number(body?.empleado_id)
    // Compatibilidad: clientes anteriores reintentan el acceso enviando solo
    // email/nombre/password. En ese caso resolvemos la ficha por email dentro
    // del tenant ya resuelto por requireEmployee().
    const linkExisting = empleadoData == null

    if (!email || !email.includes('@')) {
      return jsonResponse({ success: false, error: 'El email es requerido' }, 400)
    }
    if (!nombre) {
      return jsonResponse({ success: false, error: 'El nombre es requerido' }, 400)
    }

    let existingTarget: {
      id: number
      app_user_id: string | null
      auth_id: string | null
      email: string | null
      rol: string
      activo: boolean | null
      nombre: string
    } | null = null

    let newEmployeePayload: Record<string, unknown> | null = null
    let accessRole: 'admin' | 'operador'
    let accessStatus: 'active' | 'disabled' = 'active'

    if (linkExisting) {
      let targetQuery = context.admin
        .from('empleados')
        .select('id, app_user_id, auth_id, email, rol, activo, nombre')

      targetQuery = Number.isInteger(empleadoId) && empleadoId > 0
        ? targetQuery.eq('id', empleadoId)
        : targetQuery.eq('email', email)

      const { data: target, error: targetError } = await targetQuery.maybeSingle()

      if (targetError) throw targetError
      if (!target) {
        return jsonResponse({ success: false, error: 'El empleado no existe' }, 404)
      }

      const role = validRole(target.rol)
      if (!role) {
        return jsonResponse({ success: false, error: 'Rol de empleado inválido' }, 409)
      }
      if (target.activo !== true) {
        return jsonResponse({
          success: false,
          error: 'Reactiva al empleado antes de crear su acceso.',
        }, 409)
      }
      if (
        String(target.app_user_id ?? '').trim().length > 0 ||
        String(target.auth_id ?? '').trim().length > 0
      ) {
        return jsonResponse({
          success: false,
          error: 'El empleado ya tiene un acceso vinculado.',
        }, 409)
      }

      const storedEmail = String(target.email ?? '').trim().toLowerCase()
      if (storedEmail && storedEmail !== email) {
        return jsonResponse({
          success: false,
          error: 'El correo no coincide con la ficha del empleado.',
        }, 409)
      }

      accessRole = role
      existingTarget = {
        id: Number(target.id),
        app_user_id: null,
        auth_id: null,
        email: storedEmail || null,
        rol: role,
        activo: true,
        nombre: String(target.nombre ?? '').trim(),
      }
    } else {
      if (typeof empleadoData !== 'object' || Array.isArray(empleadoData)) {
        return jsonResponse({ success: false, error: 'empleado_data inválido' }, 400)
      }

      const rawEmployee = empleadoData as Record<string, unknown>
      const role = validRole(rawEmployee.rol)
      if (!role) {
        return jsonResponse({ success: false, error: 'Rol de empleado inválido' }, 400)
      }

      const employeeActive = rawEmployee.activo !== false
      accessRole = role
      accessStatus = employeeActive ? 'active' : 'disabled'

      // No aceptamos columnas sensibles arbitrarias del cliente. organization_id,
      // id, app_user_id/auth_id, creado_por y timestamps se determinan en backend.
      // organization_id debe viajar explícito porque service_role no puede depender
      // de RLS ni de un tenant enviado por el cliente.
      newEmployeePayload = {
        organization_id: context.organizationId,
        nombre,
        cargo: cleanOptional(rawEmployee.cargo),
        telefono: cleanOptional(rawEmployee.telefono),
        email,
        rol: role,
        activo: employeeActive,
        creado_por: context.user.id,
        fecha_actualizacion: new Date().toISOString(),
      }

      const { data: duplicate, error: duplicateError } = await context.admin
        .from('empleados')
        .select('id')
        .eq('email', email)
        .maybeSingle()
      if (duplicateError) throw duplicateError
      if (duplicate) {
        return jsonResponse({
          success: false,
          error: 'Ese correo ya está asociado a un empleado existente',
        }, 409)
      }
    }

    if (!password) {
      const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
      const randomValues = new Uint32Array(12)
      crypto.getRandomValues(randomValues)
      password = Array.from(randomValues)
        .map((value) => chars[value % chars.length])
        .join('')
    }

    const { data: newUser, error: createError } =
      await context.admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: {
          nombre,
          force_password_change: true,
        },
      })

    if (createError || !newUser.user) {
      throw createError ?? new Error('No se pudo crear el acceso Auth')
    }

    const newAuthId = newUser.user.id

    // app_users es la autoridad canónica de tenant/rol. No se confía en metadata
    // del JWT ni en organization_id del body.
    const { error: membershipError } = await context.admin
      .from('app_users')
      .insert({
        user_id: newAuthId,
        organization_id: context.organizationId,
        status: accessStatus,
        base_role: accessRole,
      })

    if (membershipError) {
      await deleteAuthBestEffort(context.admin, newAuthId)
      throw new Error(
        `No se pudo crear la membresía de la organización: ${membershipError.message}`,
      )
    }

    if (existingTarget) {
      const { data: linked, error: linkError } = await context.admin
        .from('empleados')
        .update({
          app_user_id: newAuthId,
          auth_id: newAuthId,
          email,
          fecha_actualizacion: new Date().toISOString(),
        })
        .eq('id', existingTarget.id)
        .is('app_user_id', null)
        .is('auth_id', null)
        .select('id, app_user_id, auth_id')
        .maybeSingle()

      if (
        !linkError &&
        String(linked?.app_user_id ?? '') === newAuthId &&
        String(linked?.auth_id ?? '') === newAuthId
      ) {
        return jsonResponse({
          success: true,
          message: 'Acceso vinculado exitosamente',
          user_id: newAuthId,
          employee_id: existingTarget.id,
          password,
        })
      }

      const { data: verified, error: verifyError } = await context.admin
        .from('empleados')
        .select('id, app_user_id, auth_id')
        .eq('id', existingTarget.id)
        .maybeSingle()

      if (
        !verifyError &&
        String(verified?.app_user_id ?? '') === newAuthId &&
        String(verified?.auth_id ?? '') === newAuthId
      ) {
        return jsonResponse({
          success: true,
          message: 'Acceso vinculado exitosamente',
          user_id: newAuthId,
          employee_id: existingTarget.id,
          password,
          recovered: true,
        })
      }

      if (!verifyError) {
        await rollbackAccessBestEffort(
          context.admin,
          context.organizationId,
          newAuthId,
        )
      }

      if (verifyError) {
        // No conocemos con certeza si el vínculo se persistió: deshabilitamos la
        // membresía antes de propagar el error para no dejar acceso ambiguo.
        await rollbackAccessBestEffort(
          context.admin,
          context.organizationId,
          newAuthId,
        )
        throw new Error(
          'No se pudo confirmar la vinculación del acceso. Revisa el empleado antes de reintentar.',
        )
      }
      throw linkError ?? new Error('No se pudo vincular el acceso al empleado')
    }

    const { data: inserted, error: insertError } = await context.admin
      .from('empleados')
      .insert({
        ...newEmployeePayload!,
        app_user_id: newAuthId,
        auth_id: newAuthId,
      })
      .select('id, app_user_id, auth_id')
      .single()

    if (
      !insertError &&
      inserted &&
      String(inserted.app_user_id ?? '') === newAuthId &&
      String(inserted.auth_id ?? '') === newAuthId
    ) {
      return jsonResponse({
        success: true,
        message: 'Usuario creado exitosamente',
        user_id: newAuthId,
        employee_id: Number(inserted.id),
        password,
      })
    }

    const { data: verified, error: verifyError } = await context.admin
      .from('empleados')
      .select('id, app_user_id, auth_id')
      .eq('email', email)
      .maybeSingle()

    if (
      !verifyError &&
      String(verified?.app_user_id ?? '') === newAuthId &&
      String(verified?.auth_id ?? '') === newAuthId
    ) {
      return jsonResponse({
        success: true,
        message: 'Usuario creado exitosamente',
        user_id: newAuthId,
        employee_id: Number(verified!.id),
        password,
        recovered: true,
      })
    }

    await rollbackAccessBestEffort(
      context.admin,
      context.organizationId,
      newAuthId,
    )

    if (verifyError) {
      throw new Error(
        'No se pudo confirmar la vinculación del nuevo empleado. Revisa el listado antes de reintentar.',
      )
    }

    throw insertError ?? new Error('No se pudo vincular el empleado al acceso Auth')
  } catch (error) {
    const status = error instanceof AuthGuardError ? error.status : 400
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    }, status)
  }
}))