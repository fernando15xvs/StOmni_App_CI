import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) =>
  fs.readFileSync(path.join(root, relativePath), 'utf8');
const need = (errors, source, expression, message) => {
  if (!expression.test(source)) errors.push(`Falta: ${message}`);
};
const forbid = (errors, source, expression, message) => {
  if (expression.test(source)) errors.push(message);
};

function verify(sources) {
  const errors = [];

  need(
    errors,
    sources.migration,
    /CREATE OR REPLACE FUNCTION public\.get_current_business_configuration_v1\(\)[\s\S]*?private\.require_current_organization_id\(\)[\s\S]*?private\.has_permission\('tenant\.read'\)[\s\S]*?WHERE c\.organization_id = v_organization_id/i,
    'RPC de branding deriva tenant, exige lectura y filtra por organización',
  );
  need(
    errors,
    sources.migration,
    /'razon_social', 'nombre_comercial'[\s\S]*?'logo_url'/i,
    'configuración autoritativa conserva nombre comercial y logo',
  );
  need(
    errors,
    sources.migration,
    /CREATE POLICY logos_tenant_admin_insert[\s\S]*?split_part\(name, '\/', 1\) = private\.current_organization_id\(\)::text/i,
    'Storage restringe escritura de logos al prefijo tenant',
  );

  need(
    errors,
    sources.domain,
    /class BusinessBranding[\s\S]*?organizationId[\s\S]*?effectiveDisplayName[\s\S]*?parseLogoUri/,
    'contrato de identidad visual compartido',
  );
  forbid(
    errors,
    sources.domain,
    /package:flutter|Supabase|BuildContext/,
    'BusinessBranding depende de UI o infraestructura',
  );
  need(
    errors,
    sources.mapper,
    /row\['organization_id'\][\s\S]*?row\['nombre_comercial'\][\s\S]*?row\['logo_url'\]/,
    'mapper reutiliza configuracion_negocio',
  );
  need(
    errors,
    sources.gateway,
    /\.rpc\(\s*'get_current_business_configuration_v1'\s*\)/,
    'gateway usa la RPC tenant-aware existente',
  );
  forbid(
    errors,
    sources.gateway,
    /\.from\(\s*['"]configuracion_negocio['"]\s*\)/,
    'gateway de branding consulta la tabla directamente',
  );
  forbid(
    errors,
    sources.gateway,
    /p_organization_id|['"]organization_id['"]\s*:/,
    'gateway permite seleccionar organization_id desde el cliente',
  );
  need(
    errors,
    sources.gateway,
    /business_branding_v1:\$cacheNamespace:\$user/,
    'caché visual aislada por usuario y backend',
  );
  need(
    errors,
    sources.gateway,
    /if \(!allowOffline \|\| !ErrorMapper\.isConnectionError\(error\)\) rethrow;/,
    'fallback visual offline sólo ante error de conexión explícito',
  );
  need(
    errors,
    sources.providers,
    /FutureProvider\.autoDispose\s*\.family<BusinessBranding,\s*bool>/,
    'provider visual se descarta entre shells/sesiones',
  );

  for (const [name, source] of Object.entries({
    'mobile/Web': sources.mobile,
    Desktop: sources.desktop,
  })) {
    need(
      errors,
      source,
      /businessBrandingProvider\(/,
      `${name} consume el provider compartido`,
    );
    need(
      errors,
      source,
      /effectiveDisplayName[\s\S]*?Image\.network\(/,
      `${name} presenta nombre y logo tenant`,
    );
    forbid(
      errors,
      source,
      /import ['"]dart:io['"]|\bPlatform\./,
      `${name} usa una API de plataforma para branding`,
    );
  }

  need(
    errors,
    sources.configurationPage,
    /LayoutBuilder\([\s\S]*?BoxConstraints\(maxWidth: 840\)/,
    'editor de marca mantiene ancho responsive en Web/tablet',
  );
  need(
    errors,
    sources.configurationPage,
    /businessBrandingProvider\(false\)/,
    'guardar configuración invalida el branding online',
  );
  need(
    errors,
    sources.configurationService,
    /static String _activeAuthUserId[\s\S]*?currentUserId != _activeAuthUserId[\s\S]*?clearActiveConfiguration\(\)/,
    'snapshot fiscal/visual está ligado a la sesión Auth',
  );
  need(
    errors,
    sources.auth,
    /ConfiguracionService\.clearActiveConfiguration\(\)/,
    'Auth limpia branding fiscal al cambiar de sesión',
  );

  need(
    errors,
    sources.pdfLoader,
    /BusinessBranding\.parseLogoUri[\s\S]*?startsWith\('image\/'\)[\s\S]*?_maxLogoBytes/,
    'loader PDF valida origen, tipo y tamaño del logo',
  );
  for (const [name, source] of Object.entries({
    Cotización: sources.quotation,
    Ticket: sources.ticket,
  })) {
    need(
      errors,
      source,
      /fiscalProfile\?\.tradeName[\s\S]*?legalName != displayName/,
      `${name} usa nombre comercial y conserva razón social`,
    );
  }

  need(
    errors,
    sources.tests,
    /mapper usa nombre comercial y tenant devuelto por backend[\s\S]*?logo admite HTTPS y loopback local[\s\S]*?snapshot visual expira/,
    'pruebas Dart del contrato de branding',
  );
  need(
    errors,
    sources.pgTap,
    /select plan\(12\)[\s\S]*?get_current_business_configuration_v1[\s\S]*?logos_tenant_admin_insert/i,
    'pgTAP de branding y Storage tenant-aware',
  );

  return errors;
}

function readSources() {
  return {
    migration: read(
      'supabase/migrations/20260907030554_saas_domain_configuration_tenant.sql',
    ),
    domain: read('packages/core_logic/lib/business/domain/business_branding.dart'),
    mapper: read('packages/core_logic/lib/business/data/business_branding_mapper.dart'),
    gateway: read(
      'packages/core_logic/lib/business/data/supabase_business_branding_gateway.dart',
    ),
    providers: read(
      'packages/core_logic/lib/business/providers/business_branding_providers.dart',
    ),
    configurationService: read(
      'packages/core_logic/lib/services/configuracion_service.dart',
    ),
    auth: read('packages/core_logic/lib/auth/controllers/auth_controller.dart'),
    mobile: read('packages/mobile_app/lib/home/widgets/dashboard_tab.dart'),
    desktop: read(
      'packages/desktop_app/lib/features/home/desktop_home_shell.dart',
    ),
    configurationPage: read(
      'packages/mobile_app/lib/features/configuracion/pages/configuracion_negocio_page.dart',
    ),
    pdfLoader: read(
      'packages/mobile_app/lib/platform/documents/pdf_branding_loader.dart',
    ),
    quotation: read('packages/core_logic/lib/pdf/cotizacion_pdf_renderer.dart'),
    ticket: read('packages/core_logic/lib/pdf/venta_ticket_pdf_renderer.dart'),
    tests: read('packages/core_logic/test/business/business_branding_test.dart'),
    pgTap: read(
      'supabase/tests/database/business_branding_contract_test.sql',
    ),
  };
}

function selfTest() {
  const valid = readSources();
  const initial = verify(valid);
  if (initial.length) {
    console.error('SaaS business branding self-test FAILED (contrato actual rechazado):');
    initial.forEach((error) => console.error(`  - ${error}`));
    process.exit(1);
  }

  const cases = [
    [
      'tenant forjado',
      {
        ...valid,
        gateway: `${valid.gateway}\nconst bad = 'p_organization_id';`,
      },
    ],
    [
      'lectura directa',
      {
        ...valid,
        gateway: `${valid.gateway}\nclient.from('configuracion_negocio');`,
      },
    ],
    [
      'provider persistente',
      {
        ...valid,
        providers: valid.providers.replace(
          /FutureProvider\.autoDispose\s*\.family/,
          'FutureProvider.family',
        ),
      },
    ],
    [
      'snapshot entre sesiones',
      {
        ...valid,
        auth: valid.auth.replaceAll(
          'ConfiguracionService.clearActiveConfiguration();',
          '',
        ),
      },
    ],
    [
      'API móvil',
      { ...valid, mobile: `${valid.mobile}\nfinal bad = Platform.isAndroid;` },
    ],
  ];

  const missed = cases
    .filter(([, mutated]) => verify(mutated).length === 0)
    .map(([name]) => name);
  if (missed.length) {
    console.error('SaaS business branding self-test FAILED:');
    missed.forEach((name) => console.error(`  - no detectó ${name}`));
    process.exit(1);
  }
  console.log(`SaaS business branding self-test OK (${cases.length} límites).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(readSources());
if (errors.length) {
  console.error('SaaS business branding gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS business branding gate OK (F8.4).');
console.log('  - configuración/perfil existentes siguen siendo autoritativos');
console.log('  - nombre y logo tenant-aware en mobile, Web, Desktop y PDFs');
console.log('  - caché visual offline aislada y snapshots de sesión invalidados');
