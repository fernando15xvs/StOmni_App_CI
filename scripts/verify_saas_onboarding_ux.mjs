import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) =>
  fs.readFileSync(path.join(root, relativePath), 'utf8');
const need = (errors, source, expression, message) => {
  if (!expression.test(source)) errors.push(message);
};
const forbid = (errors, source, expression, message) => {
  if (expression.test(source)) errors.push(message);
};

function authorizationGetter(source) {
  const start = source.indexOf('bool get isAuthorized');
  const end = source.indexOf('bool get requiresOrganizationSetup', start);
  if (start < 0) return '';
  return source.slice(start, end < 0 ? start + 600 : end);
}

function verifySecurityBoundaries(errors, sources) {
  const authorized = authorizationGetter(sources.session);
  need(
    errors,
    authorized,
    /SessionValidationStatus\.online/,
    'isAuthorized no reconoce autorización online',
  );
  need(
    errors,
    authorized,
    /SessionValidationStatus\.offline/,
    'isAuthorized perdió autorización offline tenant válida',
  );
  forbid(
    errors,
    authorized,
    /organizationSetupRequired/,
    'pre-tenant fue incluido como autorización empresarial',
  );
  forbid(
    errors,
    authorized,
    /organizationSelectionRequired/,
    'selección de empresa no puede autorizar operaciones sin contexto',
  );

  for (const [name, source] of Object.entries(sources.setupScreens)) {
    forbid(
      errors,
      source,
      /(?:p_)?organization_id|organizationId/,
      `${name} recibe o construye organization_id`,
    );
    forbid(
      errors,
      source,
      /bootstrap_organization_v1/,
      `${name} accede directamente al bootstrap técnico`,
    );
  }

  need(
    errors,
    sources.signupGateway,
    /\.rpc\(\s*'create_my_organization_v1'/,
    'la UX no usa la puerta autoservicio create_my_organization_v1',
  );
  forbid(
    errors,
    sources.signupGateway,
    /\.rpc\(\s*'bootstrap_organization_v1'/,
    'el cliente conserva acceso directo a bootstrap_organization_v1',
  );
}

function verify() {
  const errors = [];
  const sources = {
    session: read(
      'packages/core_logic/lib/auth/domain/session_authorization.dart',
    ),
    policy: read(
      'packages/core_logic/lib/auth/application/validate_session_use_case.dart',
    ),
    gateway: read(
      'packages/core_logic/lib/auth/data/supabase_session_validation_gateway.dart',
    ),
    controller: read(
      'packages/core_logic/lib/auth/controllers/auth_controller.dart',
    ),
    routing: read(
      'packages/core_logic/lib/onboarding/application/saas_entry_routing_policy.dart',
    ),
    onboardingProviders: read(
      'packages/core_logic/lib/onboarding/providers/guided_onboarding_providers.dart',
    ),
    exports: read('packages/core_logic/lib/core_logic.dart'),
    mobileGate: read(
      'packages/mobile_app/lib/onboarding/saas_entry_gate.dart',
    ),
    mobileSetup: read(
      'packages/mobile_app/lib/onboarding/organization_setup_page.dart',
    ),
    mobileGuide: read(
      'packages/mobile_app/lib/onboarding/guided_onboarding_page.dart',
    ),
    splash: read('packages/mobile_app/lib/splash/splash_screen.dart'),
    login: read('packages/mobile_app/lib/auth/pages/login_page.dart'),
    desktopGate: read(
      'packages/desktop_app/lib/features/auth/desktop_auth_gate.dart',
    ),
    desktopPassword: read(
      'packages/desktop_app/lib/features/auth/desktop_password_change_view.dart',
    ),
    desktopOnboarding: read(
      'packages/desktop_app/lib/features/onboarding/desktop_saas_onboarding.dart',
    ),
    sessionTests: read(
      'packages/core_logic/test/auth/validate_session_use_case_test.dart',
    ),
    routingTests: read(
      'packages/core_logic/test/onboarding/saas_entry_routing_policy_test.dart',
    ),
    signupGateway: read(
      'packages/core_logic/lib/onboarding/data/supabase_organization_signup_gateway.dart',
    ),
    tenantScope: read(
      'packages/core_logic/lib/onboarding/application/tenant_request_scope.dart',
    ),
    scopedRpc: read(
      'packages/core_logic/lib/onboarding/data/supabase_tenant_request_gateway.dart',
    ),
    tenantScopeTests: read(
      'packages/core_logic/test/onboarding/tenant_request_scope_test.dart',
    ),
    tenantCache: read(
      'packages/core_logic/lib/auth/data/tenant_authorization_cache.dart',
    ),
    tenantCacheTests: read(
      'packages/core_logic/test/auth/tenant_authorization_cache_test.dart',
    ),
    legacySessionCache: read(
      'packages/core_logic/lib/auth/data/auth_session_cache.dart',
    ),
    tenantPendingQueue: read(
      'packages/core_logic/lib/database/tenant_pending_sale_queue.dart',
    ),
    persistentQueueStore: read(
      'packages/core_logic/lib/database/pending_sale_queue_store.dart',
    ),
    tenantQueueTests: read(
      'packages/core_logic/test/features/ventas/tenant_pending_sale_queue_test.dart',
    ),
    tenantCatalogCache: read(
      'packages/core_logic/lib/services/tenant_catalog_cache.dart',
    ),
    tenantCatalogTests: read(
      'packages/core_logic/test/features/ventas/tenant_catalog_cache_test.dart',
    ),
    tenantSelectionSession: read(
      'packages/core_logic/lib/onboarding/application/tenant_selection_session.dart',
    ),
    tenantSelectionTests: read(
      'packages/core_logic/test/onboarding/tenant_selection_session_test.dart',
    ),
    legacyPendingGuard: read(
      'packages/core_logic/lib/database/legacy_pending_sale_quarantine.dart',
    ),
    legacyPendingTests: read(
      'packages/core_logic/test/features/ventas/legacy_pending_sale_quarantine_test.dart',
    ),
    scopedSaleSync: read(
      'packages/core_logic/lib/sync/data/tenant_pending_sale_sync_coordinator.dart',
    ),
    scopedSaleSyncTests: read(
      'packages/core_logic/test/sync/application/tenant_pending_sale_sync_coordinator_test.dart',
    ),
    saleRepository: read(
      'packages/core_logic/lib/features/ventas/data/ventas_repository.dart',
    ),
    scopedSubmissionGateway: read(
      'packages/core_logic/lib/features/ventas/data/tenant_pending_sale_queue_gateway.dart',
    ),
    scopedSubmissionTests: read(
      'packages/core_logic/test/features/ventas/tenant_pending_sale_queue_gateway_test.dart',
    ),
    scopedSaleContext: read(
      'packages/core_logic/lib/features/ventas/data/tenant_venta_context_repository.dart',
    ),
    scopedSaleContextTests: read(
      'packages/core_logic/test/features/ventas/tenant_venta_context_repository_test.dart',
    ),
  };
  sources.setupScreens = {
    'alta mobile/web': sources.mobileSetup,
    'alta desktop': sources.desktopOnboarding,
  };

  verifySecurityBoundaries(errors, sources);

  need(
    errors,
    sources.session,
    /organizationSetupRequired/,
    'falta estado pre-tenant explícito',
  );
  need(
    errors,
    sources.policy,
    /clearCachedAuthorization\(userId\)[\s\S]*?canStartOrganizationSignup\(userId\)/,
    'la política no elimina cache operativo antes de clasificar pre-tenant',
  );
  need(
    errors,
    sources.policy,
    /on SessionValidationUnavailable[\s\S]*?SessionValidationStatus\.unavailable/,
    'una caída durante elegibilidad pre-tenant no falla cerrada',
  );
  need(
    errors,
    sources.gateway,
    /\.rpc\('get_organization_signup_state_v1'\)/,
    'elegibilidad pre-tenant no se verifica en backend F8.1',
  );
  need(
    errors,
    sources.gateway,
    /clearCachedAuthorization\([\s\S]*?AuthSessionCache\.clear\(\)/,
    'gateway no puede retirar autorización offline pre-tenant',
  );

  need(
    errors,
    sources.controller,
    /SessionValidationStatus sessionStatus/,
    'AuthState no conserva el resultado de la política compartida',
  );
  need(
    errors,
    sources.controller,
    /finishOrganizationSetup\(\)[\s\S]*?allowOffline: false[\s\S]*?SessionValidationStatus\.online/,
    'post-alta no exige revalidación tenant online',
  );
  need(
    errors,
    sources.controller,
    /organizationSetupRequired\s*\|\|\s*SessionValidationStatus\.organizationSelectionRequired\s*=>\s*AuthRevalidationResult\.denied/,
    'operaciones podrían revalidar pre-tenant/selección pendiente como válido',
  );
  need(
    errors,
    sources.policy,
    /clearCachedAuthorization\(userId\)[\s\S]*?requiresOrganizationSelection\(userId\)/,
    'sesión sin tenant no borra caché antes de exigir selección',
  );
  need(
    errors,
    sources.routing,
    /SessionValidationStatus\.organizationSelectionRequired\s*=>\s*SaasEntryRoute\.organizationSelectionRequired/,
    'routing no bloquea Home mientras falta selección de empresa',
  );
  const signIn = sources.controller.slice(
    sources.controller.indexOf('Future<bool> signIn'),
    sources.controller.indexOf('Future<void> _saveRememberPreference'),
  );
  forbid(
    errors,
    signIn,
    /from\(['"]app_users['"]\)|get_my_tenant_context_v1/,
    'signIn volvió a implementar validación tenant manual',
  );
  need(
    errors,
    signIn,
    /validateSessionUseCaseProvider/,
    'signIn no usa ValidateSessionUseCase compartido',
  );

  need(
    errors,
    sources.routing,
    /enum SaasEntryRoute[\s\S]*?signedOut[\s\S]*?passwordChangeRequired[\s\S]*?organizationSetupRequired[\s\S]*?onboardingRequired[\s\S]*?authorized[\s\S]*?offlineAuthorized/,
    'la política de routing no modela todos los destinos SaaS',
  );
  need(
    errors,
    sources.routing,
    /SessionValidationStatus\.offline => SaasEntryRoute\.offlineAuthorized/,
    'offline tenant válido no entra directamente a Home',
  );
  need(
    errors,
    sources.routing,
    /SessionValidationStatus\.organizationSetupRequired =>[\s\S]*?SaasEntryRoute\.organizationSetupRequired/,
    'routing no separa alta pre-tenant',
  );
  need(
    errors,
    sources.routing,
    /SessionValidationStatus\.online\s*=>\s*onboardingCompleted == true[\s\S]*?SaasEntryRoute\.authorized[\s\S]*?SaasEntryRoute\.onboardingRequired/,
    'sesión online puede saltarse onboarding incompleto',
  );

  for (const [name, source] of Object.entries({
    'login mobile': sources.login,
    'splash mobile/web': sources.splash,
    'gate mobile/web': sources.mobileGate,
    'gate desktop': sources.desktopGate,
  })) {
    need(
      errors,
      source,
      /SaasEntryRoutingPolicy/,
      `${name} no reutiliza la política de routing compartida`,
    );
  }

  need(
    errors,
    sources.splash,
    /SaasEntryRoute\.passwordChangeRequired[\s\S]*?CambiarPasswordPage/,
    'splash no restaura el cambio obligatorio de contraseña',
  );
  need(
    errors,
    sources.login,
    /SaasEntryRoute\.passwordChangeRequired[\s\S]*?CambiarPasswordPage/,
    'login mobile no prioriza cambio obligatorio de contraseña',
  );
  need(
    errors,
    sources.mobileGate,
    /SaasEntryRoute\.organizationSetupRequired[\s\S]*?OrganizationSetupPage/,
    'mobile/web no enruta pre-tenant a alta',
  );
  need(
    errors,
    sources.mobileGate,
    /SaasEntryRoute\.offlineAuthorized[\s\S]*?return _home\(\)/,
    'mobile/web perdió fallback offline tenant',
  );
  need(
    errors,
    sources.mobileSetup,
    /create\([\s\S]*?OrganizationSignupRequest/,
    'alta mobile/web no usa el caso de uso F8.1',
  );
  need(
    errors,
    sources.mobileSetup,
    /finishOrganizationSetup\(\)/,
    'alta mobile/web entra sin reautorizar tenant',
  );
  need(
    errors,
    sources.mobileGuide,
    /completeCurrentStep\(_progress\)/,
    'guía mobile/web puede saltarse el state machine',
  );
  forbid(
    errors,
    `${sources.mobileGate}\n${sources.mobileSetup}\n${sources.mobileGuide}`,
    /import ['"]dart:io['"]|\bPlatform\./,
    'onboarding mobile/web usa una API exclusiva de plataforma móvil',
  );

  need(
    errors,
    sources.desktopGate,
    /SessionValidationStatus _sessionStatus/,
    'desktop no conserva estados explícitos de sesión',
  );
  need(
    errors,
    sources.desktopGate,
    /SaasEntryRoute\.passwordChangeRequired[\s\S]*?DesktopPasswordChangeView/,
    'desktop restore no enruta cambio obligatorio de contraseña',
  );
  need(
    errors,
    sources.desktopGate,
    /SaasEntryRoute\.organizationSetupRequired[\s\S]*?DesktopOrganizationSetupView/,
    'desktop no enruta alta de empresa',
  );
  need(
    errors,
    sources.desktopGate,
    /SaasEntryRoute\.offlineAuthorized[\s\S]*?DesktopHomeShell/,
    'desktop perdió fallback offline tenant',
  );
  need(
    errors,
    sources.desktopPassword,
    /cambiarPassword\([\s\S]*?onSessionChanged/,
    'desktop no revalida después del cambio obligatorio de contraseña',
  );
  need(
    errors,
    sources.desktopOnboarding,
    /finishOrganizationSetup\(\)/,
    'desktop entra tras alta sin reautorizar tenant',
  );
  need(
    errors,
    sources.desktopOnboarding,
    /completeCurrentStep\(_progress\)/,
    'desktop puede saltarse el state machine',
  );

  need(
    errors,
    sources.onboardingProviders,
    /FutureProvider\.autoDispose<GuidedOnboardingProgress>/,
    'progreso de onboarding puede filtrarse entre sesiones tenant',
  );
  need(
    errors,
    sources.sessionTests,
    /pre-tenant nunca reutiliza cache/,
    'falta regresión de cache offline pre-tenant',
  );
  need(
    errors,
    sources.routingTests,
    /sesión online incompleta abre configuración guiada/,
    'falta prueba de routing para onboarding incompleto',
  );
  need(
    errors,
    sources.routingTests,
    /autorización offline válida abre Home sin consultar onboarding/,
    'falta prueba de routing offline',
  );
  need(
    errors,
    sources.exports,
    /export 'onboarding\/application\/saas_entry_routing_policy\.dart';/,
    'core_logic no exporta la política compartida',
  );

  // 2D-I3: explicit tenant request scope is read-only, request-local and
  // checks Auth/selection both before and after network await.
  need(
    errors,
    sources.tenantScope,
    /currentAuthUserId\(\) == authUserId[\s\S]*?currentSelectedOrganizationId\(\) == organizationId/,
    'tenant request scope no vincula usuario y organización activa',
  );
  need(
    errors,
    sources.scopedRpc,
    /\.rpc\('get_my_tenant_context_v1'\)[\s\S]*?\.setHeader\([\s\S]*?TenantRequestScope\.organizationHeader[\s\S]*?organizationId/,
    'verificación del tenant no adjunta selector sólo a la petición',
  );
  forbid(
    errors,
    sources.scopedRpc,
    /(?:client\.headers\s*=|client\.rest\.headers\[|client\.headers\[)/,
    'el selector no debe modificar cabeceras globales Supabase',
  );
  need(
    errors,
    sources.tenantScopeTests,
    /two simultaneous sessions cannot overwrite each other headers/,
    'faltan pruebas de peticiones simultáneas A/B independientes',
  );
  need(
    errors,
    sources.tenantCache,
    /'schema_version': 3/,
    'el cache offline tenant no está versionado como v3',
  );
  need(
    errors,
    sources.tenantCache,
    /auth_validated_session_v3:/,
    'el cache v3 no está separado por usuario y organización',
  );
  need(
    errors,
    sources.tenantCacheTests,
    /tenant-specific purge does not disturb other tenant/,
    'faltan pruebas de limpieza por tenant sin afectar otra empresa',
  );
  need(
    errors,
    sources.legacySessionCache,
    /TenantAuthorizationCache\.clearAll\(\)/,
    'logout debe purgar todas las autorizaciones tenant v3',
  );

  // I3: legacy tickets and global product cache must remain quarantined.
  // New storage is namespaced by BOTH Auth user and selected organization.
  need(
    errors,
    sources.persistentQueueStore,
    /databaseNameOverride/,
    'SQLite pending queue cannot choose a tenant-specific database',
  );
  need(
    errors,
    sources.persistentQueueStore,
    /webStorageKeyOverride/,
    'Browser fallback pending queue is still globally shared',
  );
  need(
    errors,
    sources.tenantPendingQueue,
    /stomni_pending_v2_/,
    'New pending sale SQLite files are not tenant namespaced',
  );
  need(
    errors,
    sources.tenantPendingQueue,
    /stomni_pending_web_v2:/,
    'Browser queue namespace does not include user and tenant',
  );
  need(
    errors,
    sources.tenantPendingQueue,
    /_requireOwnPayload\(payload\)/,
    'Offline ticket enqueue does not validate tenant provenance',
  );
  need(
    errors,
    sources.tenantPendingQueue,
    /scope\.execute<T>/,
    'Offline queue does not verify session and tenant after writes',
  );
  forbid(
    errors,
    sources.tenantPendingQueue,
    /(?:ventas_pendientes_queue_web_v1|ferreteria_pending_sales_v1\.db)/,
    'New tenant queue must never overwrite legacy unbound tickets',
  );
  need(
    errors,
    sources.tenantCatalogCache,
    /catalogo_cache_v2:/,
    'Catalog cache is not namespaced to selected tenant',
  );
  need(
    errors,
    sources.tenantCatalogCache,
    /_requireOwnProduct/,
    'Catalog cache accepts product rows without verifying tenant',
  );
  need(
    errors,
    sources.tenantQueueTests,
    /same request_id in A and B never overwrites another company/,
    'Missing SQLite isolation test with duplicate request id',
  );
  need(
    errors,
    sources.tenantQueueTests,
    /existing historical SQLite sales stay untouched and quarantined/,
    'Missing test preserving unmigrated historical tickets',
  );
  need(
    errors,
    sources.tenantCatalogTests,
    /one company cannot read cached products of another/,
    'Missing cross-company catalog cache tests',
  );

  need(
    errors,
    sources.tenantSelectionSession,
    /_candidateOrganizationId = organizationId/,
    'Tenant selection does not hold a request-local candidate',
  );
  need(
    errors,
    sources.tenantSelectionSession,
    /currentAuthUserId\(\) != userId/,
    'A stale Auth identity could activate a former tenant',
  );
  need(
    errors,
    sources.tenantSelectionSession,
    /attempt != _generation/,
    'Concurrent tenant responses are not ordered by generation',
  );
  need(
    errors,
    sources.tenantSelectionSession,
    /_verified = null/,
    'A pending switch does not revoke the previous active tenant',
  );
  need(
    errors,
    sources.tenantSelectionTests,
    /two windows for same auth user keep separate independent selections/,
    'Missing per-window A/B selection isolation regression',
  );
  need(
    errors,
    sources.tenantSelectionTests,
    /later B selection wins and stale A response cannot replace it/,
    'Missing stale-response rejection during rapid tenant changes',
  );

  need(
    errors,
    sources.legacyPendingGuard,
    /legacyQueue\.count\(\)/,
    'Tenant activation does not inspect the existing SQLite pending queue',
  );
  need(
    errors,
    sources.legacyPendingGuard,
    /prefs\.getString\(historicalPreferencesKey\)/,
    'Tenant activation ignores the old preferences sales queue',
  );
  need(
    errors,
    sources.legacyPendingGuard,
    /!status\.safeToSwitch/,
    'Unowned historical tickets do not block real company switching',
  );
  forbid(
    errors,
    sources.legacyPendingGuard,
    /legacyQueue\.(?:deleteByRequestId|clear|upsertPayload)\(/,
    'Legacy-ticket quarantine must never delete or migrate historical sales',
  );
  need(
    errors,
    sources.legacyPendingTests,
    /historical SQLite ticket blocks activation without erasing it/,
    'Missing durable legacy-ticket activation block regression',
  );
  need(
    errors,
    sources.legacyPendingTests,
    /old shared preferences ticket is quarantined, not migrated/,
    'Missing shared preferences legacy-sale quarantine regression',
  );

  need(
    errors,
    sources.scopedSaleSync,
    /legacyQuarantine\.requireNoUnattributedTickets\(\)/,
    'Sync scoped must block unattributed historical tickets',
  );
  need(
    errors,
    sources.scopedSaleSync,
    /_requireServerMembership\(\)/,
    'Scoped ticket sync must verify selected tenant from server',
  );
  need(
    errors,
    sources.scopedSaleSync,
    /adapter\.sendTicket\(scope: scope, sale: sale\)/,
    'Ticket sync must pass the immutable tenant scope to its transport',
  );
  need(
    errors,
    sources.scopedSaleSync,
    /await queue\.deleteByRequestId\(record\.requestId\)/,
    'Ticket sync must delete local pending row only after confirmed send',
  );
  need(
    errors,
    sources.scopedSaleSync,
    /if \(!_stillSelected\(\)\)/,
    'Selected-company switch must stop in-flight sync safely',
  );
  need(
    errors,
    sources.scopedSaleSync,
    /PendingSaleQueueStatus\.processing/,
    'Scoped sync must not claim another worker processing a ticket',
  );
  need(
    errors,
    sources.scopedSaleSyncTests,
    /session switch during network write retains in-flight ticket/,
    'Missing retry test for Auth switch during sale submission',
  );
  need(
    errors,
    sources.scopedSaleSyncTests,
    /equal request IDs in two organizations never mix queues/,
    'Missing same-id cross-company sync regression',
  );
  need(
    errors,
    sources.scopedSaleSyncTests,
    /failed server write remains in the tenant queue for safe retry/,
    'Missing retry test for transient backend failure',
  );

  need(
    errors,
    sources.saleRepository,
    /TenantRequestScope\? tenantScope/,
    'Sale repository does not support explicit per-request tenant scope',
  );
  need(
    errors,
    sources.saleRepository,
    /tenantScope\.execute<dynamic>\(/,
    'Selected sale RPC is not bound to the Auth and tenant session lifecycle',
  );
  need(
    errors,
    sources.saleRepository,
    /currentAuthUserId: \(\) => _client\.auth\.currentUser\?\.id/,
    'Tenant-scoped sale writes do not verify the authenticated identity',
  );
  const scopedHeaders =
    sources.saleRepository.match(/await rpc\.setHeader\(/g) ?? [];
  if (scopedHeaders.length < 3) {
    errors.push('All three sale RPC variants require a request-local tenant header');
  }
  forbid(
    errors,
    sources.saleRepository,
    /_client\.headers\s*=|_client\.rest\.headers\s*=|_client\.headers\[/,
    'Sale RPC must never mutate global Supabase headers',
  );

  need(
    errors,
    sources.scopedSubmissionGateway,
    /implements PendingSaleQueueGateway/,
    'The existing sale submission port has no tenant-bound implementation',
  );
  need(
    errors,
    sources.scopedSubmissionGateway,
    /sale\.authUserId != queue\.scope\.authUserId/,
    'An offline sale could be submitted under a different Auth identity',
  );
  need(
    errors,
    sources.scopedSubmissionGateway,
    /payload\['organization_id'\] = queue\.scope\.organizationId/,
    'Offline sale payload is missing the selected tenant',
  );
  need(
    errors,
    sources.scopedSubmissionGateway,
    /await queue\.saveTicket\(payload\)/,
    'Offline sale submission bypasses the scoped durable queue',
  );
  need(
    errors,
    sources.scopedSubmissionTests,
    /parallel company queues cannot overwrite one shared request ID/,
    'Missing cross-company idempotency test for the sale submission port',
  );

  // I3 context: customer, seller and cashbox must share the immutable
  // request-local organization. A header alone is never authorization.
  need(
    errors,
    sources.scopedSaleContext,
    /implements VentaContextGateway/,
    'The existing sale context port has no selected-tenant implementation',
  );
  need(
    errors,
    sources.scopedSaleContext,
    /scope\.execute<T>/,
    'Sale context requests do not enforce Auth/selection before and after IO',
  );
  need(
    errors,
    sources.scopedSaleContext,
    /\.rpc\('get_my_tenant_context_v1'\)/,
    'Sale context must verify server membership before auxiliary operations',
  );
  const saleContextHeaders =
    sources.scopedSaleContext.match(/\.setHeader\(/g) ?? [];
  if (saleContextHeaders.length < 6) {
    errors.push('Seller, cashbox and customer requests lack per-request tenant headers');
  }
  const saleContextFilters =
    sources.scopedSaleContext.match(/\.eq\('organization_id', organizationId\)/g) ?? [];
  if (saleContextFilters.length < 3) {
    errors.push('Customer and seller requests lack explicit tenant-row filters');
  }
  need(
    errors,
    sources.scopedSaleContext,
    /'organization_id': organizationId/,
    'Tenant customer insertion does not write the selected organization',
  );
  need(
    errors,
    sources.scopedSaleContext,
    /row\['organization_id'\] != organizationId/,
    'Sale context fails to reject rows from another tenant',
  );
  need(
    errors,
    sources.scopedSaleContextTests,
    /rejects foreign customer even when its numeric id exists/,
    'Missing cross-tenant customer IDOR response validation tests',
  );
  forbid(
    errors,
    sources.scopedSaleContext,
    /_client\.headers\s*=|_client\.rest\.headers\s*=|_client\.headers\[/,
    'Sale context must not share a global tenant header between windows',
  );

  return errors;
}

function selfTest() {
  const safeSession = `
    bool get isAuthorized =>
      status == SessionValidationStatus.online ||
      status == SessionValidationStatus.offline;
    bool get requiresOrganizationSetup => false;
  `;
  const base = {
    session: safeSession,
    setupScreens: { mobile: 'create(OrganizationSignupRequest())' },
    signupGateway: "client.rpc('create_my_organization_v1')",
  };
  const safeErrors = [];
  verifySecurityBoundaries(safeErrors, base);
  if (safeErrors.length !== 0) {
    console.error('SaaS onboarding UX self-test seguro falló:', safeErrors);
    process.exit(1);
  }

  const unsafeErrors = [];
  verifySecurityBoundaries(unsafeErrors, {
    ...base,
    session: safeSession.replace(
      'SessionValidationStatus.offline',
      'SessionValidationStatus.offline || status == '
        + 'SessionValidationStatus.organizationSetupRequired',
    ),
    setupScreens: {
      mobile: 'bootstrap_organization_v1(p_organization_id: organizationId)',
    },
  });
  if (unsafeErrors.length < 3) {
    console.error('SaaS onboarding UX self-test negativo falló:', unsafeErrors);
    process.exit(1);
  }
  console.log('SaaS onboarding UX self-test OK (4 límites).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS onboarding UX gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS onboarding UX gate OK (F8.3).');
console.log('  - política única para mobile, web y desktop');
console.log('  - pre-tenant autenticado, sin Home ni autorización offline');
console.log('  - password, alta, onboarding, online y offline ruteados');
console.log('  - alta usa create_my_organization_v1 y revalida tenant online');
