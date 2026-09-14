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
    /organizationSetupRequired =>[\s\S]*?AuthRevalidationResult\.denied/,
    'operaciones podrían revalidar pre-tenant como válido',
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
    /SessionValidationStatus\.online => onboardingCompleted == true[\s\S]*?SaasEntryRoute\.authorized[\s\S]*?SaasEntryRoute\.onboardingRequired/,
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
