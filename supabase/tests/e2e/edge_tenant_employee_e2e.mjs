// T10: valid-session Edge Functions cross-tenant attacks on synthetic local data.
// Called only after two independent tenant owners have signed up in the local E2E.
export const EDGE_TENANT_SCENARIOS = Object.freeze([
  'T10-V01-valid-a-session-with-spoofed-b-header',
  'T10-V02-valid-b-session-with-spoofed-a-header',
  'T10-V03-delete-foreign-employee-a-to-b-denied',
  'T10-V04-delete-foreign-employee-b-to-a-denied',
  'T10-V05-link-foreign-employee-a-to-b-denied',
  'T10-V06-link-foreign-employee-b-to-a-denied',
  'T10-V07-both-employee-records-intact',
  'T10-V08-both-auth-memberships-still-active',
]);

function ensure(ok, message) {
  if (!ok) throw new Error(`T10 valid-JWT: ${message}`);
}

async function jsonRequest(config, { url, method = 'GET', token, body, spoofOrganization }) {
  const headers = {
    apikey: config.anonKey,
    Authorization: `Bearer ${token}`,
  };
  if (spoofOrganization) headers['x-stomni-organization-id'] = spoofOrganization;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* status alone is recorded */ }
  return { status: response.status, ok: response.ok, data };
}

function restUrl(config, table, filters) {
  const url = new URL(`${config.apiUrl}/rest/v1/${table}`);
  for (const [key, value] of Object.entries(filters)) url.searchParams.set(key, value);
  return url.toString();
}

async function serviceSelect(config, table, filters) {
  const url = restUrl(config, table, filters);
  const res = await fetch(url, {
    headers: {
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
    },
    signal: AbortSignal.timeout(20_000),
  });
  ensure(res.ok, `falló verificación local de fixture ${table} HTTP ${res.status}`);
  const data = await res.json();
  ensure(Array.isArray(data), `REST ${table} no devolvió array`);
  return data;
}

async function ownerEmployee(config, tenant) {
  const result = await serviceSelect(config, 'empleados', {
    select: 'id,organization_id,app_user_id,email,activo',
    organization_id: `eq.${tenant.organizationId}`,
    app_user_id: `eq.${tenant.userId}`,
  });
  ensure(result.length === 1 && Number.isInteger(Number(result[0].id)) && result[0].activo === true,
    `tenant ${tenant.label} carece de empleado administrador de alta`);
  return result[0];
}

async function membership(config, tenant) {
  const result = await serviceSelect(config, 'app_users', {
    select: 'user_id,organization_id,status,base_role',
    organization_id: `eq.${tenant.organizationId}`,
    user_id: `eq.${tenant.userId}`,
  });
  ensure(result.length === 1 && result[0].status === 'active' && result[0].base_role === 'admin',
    `${tenant.label} carece de membership admin activo`);
  return result[0];
}

async function invokeEdge(config, actor, foreignTenant, slug, body) {
  return jsonRequest(config, {
    url: `${config.apiUrl}/functions/v1/${slug}`,
    method: 'POST',
    token: actor.accessToken,
    spoofOrganization: foreignTenant.organizationId,
    body: { ...body, organization_id: foreignTenant.organizationId },
  });
}

export async function verifyEdgeTenantEmployees(config, a, b) {
  ensure(a.organizationId !== b.organizationId, 'A y B comparten UUID');
  const [employeeA, employeeB] = await Promise.all([
    ownerEmployee(config, a), ownerEmployee(config, b),
  ]);
  const [memberA, memberB] = await Promise.all([
    membership(config, a), membership(config, b),
  ]);
  ensure(employeeA.id !== employeeB.id, 'se esperaba un ID distinto por empleado');

  // get-persona validates the body after requireEmployee; {} cannot hit
  // any DNI/RUC provider or cache lookup. The forged tenant header must not
  // suppress a normal authenticated 400 at the handler boundary.
  for (const [actor, foreignTenant, label] of [
    [a, b, EDGE_TENANT_SCENARIOS[0]],
    [b, a, EDGE_TENANT_SCENARIOS[1]],
  ]) {
    const res = await invokeEdge(config, actor, foreignTenant, 'get-persona', {});
    ensure(res.status === 400, `${label}: se esperaba HTTP 400 tras Auth real, llegó ${res.status}`);
    console.log(`[${label}] sesión propia válida; header de empresa ajena ignorado`);
  }

  // Both handlers would mutate records if tenant scoping failed.
  // The caller has a valid JWT and the other tenant's REAL employee PK.
  for (const [actor, foreignTenant, foreignEmployee, deleteLabel, linkLabel] of [
    [a, b, employeeB, EDGE_TENANT_SCENARIOS[2], EDGE_TENANT_SCENARIOS[4]],
    [b, a, employeeA, EDGE_TENANT_SCENARIOS[3], EDGE_TENANT_SCENARIOS[5]],
  ]) {
    const del = await invokeEdge(config, actor, foreignTenant, 'delete_employee', {
      empleado_id: foreignEmployee.id,
    });
    ensure(del.status === 404, `${deleteLabel}: objeto ajeno fue visible, HTTP ${del.status}`);
    console.log(`[${deleteLabel}] empleado ajeno invisible con PK conocida`);

    const link = await invokeEdge(config, actor, foreignTenant, 'create_employee', {
      empleado_id: foreignEmployee.id,
      nombre: 'StOmni test de aislamiento',
      email: foreignEmployee.email,
    });
    ensure(link.status === 404, `${linkLabel}: empleado ajeno aceptado, HTTP ${link.status}`);
    console.log(`[${linkLabel}] vinculación ajena denegada`);
  }

  const [afterEmployeeA, afterEmployeeB, afterMemberA, afterMemberB] = await Promise.all([
    ownerEmployee(config, a), ownerEmployee(config, b),
    membership(config, a), membership(config, b),
  ]);
  ensure(JSON.stringify(afterEmployeeA) === JSON.stringify(employeeA) &&
    JSON.stringify(afterEmployeeB) === JSON.stringify(employeeB),
    'alguno de los empleados fue alterado por solicitud cruzada');
  console.log(`[${EDGE_TENANT_SCENARIOS[6]}] empleados permanecen idénticos`);

  ensure(JSON.stringify(afterMemberA) === JSON.stringify(memberA) &&
    JSON.stringify(afterMemberB) === JSON.stringify(memberB),
    'alguna membresía fue alterada por solicitud cruzada');
  console.log(`[${EDGE_TENANT_SCENARIOS[7]}] ambas membresías admin siguen activas`);

  return { count: EDGE_TENANT_SCENARIOS.length, tenant_count: 2, contains_secrets: false };
}
