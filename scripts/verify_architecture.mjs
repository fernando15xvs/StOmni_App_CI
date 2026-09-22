// Verificación estática sin Flutter, dependencias npm ni acceso a la red.
// No sustituye dart format, flutter analyze, flutter test ni pruebas SQL locales.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const packages = new Map();
const errors = [];
const coreGraph = new Map();
let checked = 0;

for (const name of readdirSync(join(root, 'packages'))) {
  const directory = join(root, 'packages', name);
  const manifest = join(directory, 'pubspec.yaml');
  if (!existsSync(manifest)) continue;
  const match = readFileSync(manifest, 'utf8').match(/^name:\s*(\S+)/m);
  if (match) packages.set(match[1], directory);
}

function* dartFiles(directory) {
  if (!existsSync(directory)) return;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* dartFiles(path);
    else if (entry.isFile() && entry.name.endsWith('.dart')) yield path;
  }
}

const normalize = (path) => path.split(sep).join('/');
const reusable = (path) => /\/(?:domain|application|usecases)\//.test(path);
const error = (path, message) =>
  errors.push(`${normalize(relative(root, path))}: ${message}`);

const typedSalesBoundaries = new Set([
  'domain/sale_cart.dart',
  'domain/sale_product_snapshot.dart',
  'domain/sale_models.dart',
  'application/procesar_venta_command.dart',
  'application/venta_submission_coordinator.dart',
  'application/sale_line_persistence_mapper.dart',
  'application/price_sale_line_use_case.dart',
  'usecases/procesar_venta_usecase.dart',
].map((path) => `features/ventas/${path}`));

for (const [name, directory] of packages) {
  for (const path of [
    ...dartFiles(join(directory, 'lib')),
    ...dartFiles(join(directory, 'test')),
  ]) {
    checked++;
    const source = readFileSync(path, 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/^\s*\/\/.*$/gm, '');
    const normalized = normalize(path);
    const isCoreLib = name === 'core_logic' && normalized.includes('/lib/');

    if (
      isCoreLib &&
      typedSalesBoundaries.has(normalize(relative(join(directory, 'lib'), path))) &&
      /Map\s*<\s*String\s*,\s*dynamic\s*>/.test(source)
    ) {
      error(path, 'mapa de persistencia escondido en frontera tipada de ventas');
    }

    if (
      name === 'mobile_app' &&
      normalized.endsWith('/controllers/carrito_controller.dart') &&
      (!source.includes('Notifier<SaleCart>') || source.includes('Map<String, dynamic>'))
    ) {
      error(path, 'el estado del carrito móvil debe ser SaleCart');
    }

    if (isCoreLib) coreGraph.set(path, []);
    const seen = new Set();
    for (const directive of source.matchAll(
      /^\s*(import|export|part)\s+['"]([^'"]+)['"][^;]*;/gm,
    )) {
      const [, kind, target] = directive;
      if (kind === 'import' && seen.has(target)) {
        error(path, `import repetido: ${target}`);
      }
      if (kind === 'import') seen.add(target);
      if (target.startsWith('dart:')) continue;

      const packageTarget = target.match(/^package:([^/]+)\/(.+)$/);
      let resolved;
      if (packageTarget && packages.has(packageTarget[1])) {
        resolved = join(packages.get(packageTarget[1]), 'lib', packageTarget[2]);
      } else if (!target.includes(':')) {
        resolved = resolve(dirname(path), target);
      }

      if (resolved && !existsSync(resolved)) {
        error(path, `destino inexistente: ${target}`);
      }
      if (isCoreLib) coreGraph.get(path).push(resolved ?? target);

      if (
        isCoreLib &&
        packageTarget &&
        packages.has(packageTarget[1]) &&
        packageTarget[1] !== name
      ) {
        error(path, `core depende de cliente: ${target}`);
      }
      if (isCoreLib && /package:(?:mobile_app|desktop_app|ferreteria_app)\//.test(target)) {
        error(path, `dependencia cliente/legado prohibida: ${target}`);
      }
      if (
        isCoreLib &&
        /package:flutter\/(?:material|widgets|cupertino)\.dart|package:(?:connectivity_plus|image_picker|onesignal_flutter|printing|file_picker|share_plus|path_provider)\//.test(target)
      ) {
        error(path, `UI o plugin móvil dentro de core: ${target}`);
      }
      if (isCoreLib && reusable(normalized)) {
        if (
          /package:(?:flutter|flutter_riverpod|riverpod|supabase_flutter|connectivity_plus|printing|image_picker|shared_preferences|sqflite)\//.test(target)
        ) {
          error(path, `framework en capa reutilizable: ${target}`);
        }
        if (
          resolved &&
          /(?:^|\/)(?:data|providers|services|database|pdf|infrastructure)\//.test(
            normalize(relative(join(directory, 'lib'), resolved)),
          )
        ) {
          error(path, `dependencia hacia infraestructura: ${target}`);
        }
        if (resolved === join(directory, 'lib', 'core_logic.dart')) {
          error(path, 'la capa reutilizable no debe importar el barrel de infraestructura');
        }
      }
    }

    if (
      isCoreLib &&
      /\b(?:BuildContext|AppLifecycleListener|ScaffoldMessenger|Navigator)\b/.test(source)
    ) {
      error(path, 'concepto de UI/lifecycle en core');
    }

    const declaration = source.search(
      /^\s*(?:class |enum |abstract |void main\(|final \w)/m,
    );
    if (
      declaration >= 0 &&
      /^\s*(?:import|export)\s+['"]/m.test(source.slice(declaration))
    ) {
      error(path, 'directiva después de una declaración');
    }
  }
}

const framework = /^package:(?:flutter|flutter_riverpod|riverpod|supabase_flutter|printing|file_picker|share_plus|path_provider|connectivity_plus|image_picker|shared_preferences|sqflite)\//;
for (const start of coreGraph.keys()) {
  if (
    !reusable(normalize(start)) &&
    !/\/(?:pdf\/|[^/]*(?:pdf_renderer|excel_service|pdf_generator_service)\.dart$)/.test(
      normalize(start),
    )
  ) {
    continue;
  }
  const seen = new Set();
  const pending = [start];
  while (pending.length) {
    const current = pending.pop();
    if (seen.has(current)) continue;
    seen.add(current);
    if (typeof current === 'string' && framework.test(current)) {
      error(start, `dependencia transitiva de framework: ${current}`);
      break;
    }
    pending.push(...(coreGraph.get(current) ?? []));
  }
}

// Supabase usa el prefijo temporal como versión. Dos archivos con la misma
// versión hacen ambiguo db reset/push aunque sus nombres completos difieran.
const migrationsDir = join(root, 'supabase', 'migrations');
const migrationVersions = new Map();
for (const name of readdirSync(migrationsDir)) {
  if (!name.endsWith('.sql')) continue;
  const match = name.match(/^(\d{14})_/);
  if (!match) continue;
  const previous = migrationVersions.get(match[1]);
  if (previous) {
    error(
      join(migrationsDir, name),
      `versión de migración duplicada ${match[1]} (también ${previous})`,
    );
  } else {
    migrationVersions.set(match[1], name);
  }
}

const contract = (path, requirements) => {
  if (!existsSync(path)) {
    error(path, 'falta el contrato de arquitectura esperado');
    return;
  }
  const source = readFileSync(path, 'utf8');
  for (const requirement of requirements) {
    if (!source.includes(requirement)) {
      error(path, `falta requisito de arquitectura: ${requirement}`);
    }
  }
};

const migration = (name) => join(migrationsDir, name);
const core = (...parts) => join(root, 'packages', 'core_logic', 'lib', ...parts);
const mobile = (...parts) => join(root, 'packages', 'mobile_app', 'lib', ...parts);
const desktop = (...parts) => join(root, 'packages', 'desktop_app', 'lib', ...parts);

const unitMigration = migration('20260904150000_product_unit_presentations.sql');
const immutableScaleMigration = migration('20260905230500_immutable_inventory_scale.sql');

for (const [path, requirements] of [
  [unitMigration, [
    'product_unit_profiles',
    'save_product_unit_profile_v1',
    'process_sale_with_units_v1',
    'presentation_snapshot',
    'validate_product_unit_profile',
    'FOR SHARE',
    'unit_profile_revision',
  ]],
  [migration('20260905183000_product_unit_quotations.sql'), [
    'guardar_cotizacion_with_units_v1',
    'detalle_cotizaciones',
    'presentation_snapshot',
    "'profile', v_profile.profile",
    'unit_profile_revision',
    'FOR SHARE',
    'guardar_cotizacion_v2',
  ]],
  [migration('20260905203000_scaled_fractional_inventory.sql'), [
    'stock_scale_snapshot',
    '_product_unit_storage_scale',
    '_validate_product_unit_profile_v2',
    'process_sale_with_units_v2',
  ]],
  [migration('20260905210000_fractional_profile_and_quotation_v2.sql'), [
    'guardar_cotizacion_with_units_v2',
    "'storage_scale',v_scale",
    "'base_quantity',v_base",
  ]],
  [migration('20260905220000_scaled_inventory_operations.sql'), [
    '_visible_base_to_stored',
    'registrar_merma_scaled_v1',
    'trasladar_stock_scaled_v1',
    'registrar_ingreso_mercaderia_scaled_v1',
    'ajustar_stock_scaled_v1',
  ]],
  [immutableScaleMigration, [
    'save_product_unit_profile_v5',
    'inventario_movimientos',
    'detalle_ventas',
    'detalle_cotizaciones',
    'no puede cambiar después de la primera operación',
  ]],
  [migration('20260905233000_electronic_configurable_presentations.sql'), [
    'process_sale_with_units_v3',
    'fiscal_unit_code',
    '_validate_product_unit_fiscal_codes_v1',
    'process_sale_with_units_v2',
  ]],
  [migration('20260905233500_fractional_credit_note_snapshots.sql'), [
    'commercial_quantity_snapshot',
    'crear_nota_credito_with_units_v3',
    'obtener_disponibilidad_nota_credito_v2',
    'stock_scale_snapshot',
  ]],
  [migration('20260905234000_employee_permission_overrides.sql'), [
    'employee_permission_overrides',
    'app_tiene_permiso',
    'get_my_effective_permissions_v1',
    'update_employee_permission_overrides_v1',
  ]],
  [migration('20260905235100_permission_enforcement.sql'), [
    'process_sale_v4',
    'process_sale_with_units_v4',
    'registrar_ingreso_mercaderia_scaled_v2',
    'registrar_merma_scaled_v2',
    'trasladar_stock_scaled_v2',
    'save_product_unit_profile_v6',
  ]],

  // Trazabilidad: persistencia, consumo, compras, FIFO y cutover de capacidades.
  [migration('20260906003000_inventory_lot_serial_traceability.sql'), [
    'product_traceability_configs',
    'inventory_lots',
    'inventory_serials',
    'register_traceable_merchandise_receipt_v1',
  ]],
  [migration('20260906003500_traceability_capability_and_expiry_guard.sql'), [
    'lot_tracking',
    'expiry_tracking',
    'serial_number_tracking',
  ]],
  [migration('20260906004000_traceable_sale_consumption.sql'), [
    '_consume_inventory_traceability_v1',
    '_consume_sale_traceability_v1',
    'inventory_traceability_consumptions',
  ]],
  [migration('20260906004500_inert_traceability_until_capability_enabled.sql'), [
    '_consume_inventory_traceability_v1',
    'get_business_profile_v1',
    'lot_tracking',
    'serial_number_tracking',
    "RETURN '[]'::jsonb",
  ]],
  [migration('20260906005000_traceable_transfers_and_waste.sql'), [
    'trasladar_stock_scaled_v3',
    'registrar_merma_scaled_v3',
  ]],
  [migration('20260906005500_traceable_movement_idempotency.sql'), [
    'inventory_traceability_consumptions',
    'trasladar_stock_scaled_v3',
    'registrar_merma_scaled_v3',
  ]],
  [migration('20260906006000_traceable_purchase_receipts.sql'), [
    'receive_purchase_order_v2',
    'register_traceable_merchandise_receipt_v1',
    'WHERE r.request_id=p_request_id',
  ]],
  [migration('20260906006500_serial_fifo_fallback.sql'), [
    '_resolve_serial_numbers_v1',
    'ORDER BY s.created_at,s.id',
    'FOR UPDATE',
  ]],
  [migration('20260906007000_enable_traceability_capabilities.sql'), [
    'lot_tracking',
    'expiry_tracking',
    'serial_number_tracking',
    'update_business_capabilities_v1',
  ]],
  [migration('20260906007500_serial_fifo_json_hardening.sql'), [
    '_resolve_serial_numbers_v1',
    'jsonb_build_array',
  ]],

  // Servicios: ítems comerciales no inventariables.
  [migration('20260906008000_non_inventory_services.sql'), [
    'es_servicio',
    'service_inventory_always_zero',
    'service_no_inventory_movements',
    'service_not_purchase_inventory',
    'service_not_traceable',
    'save_service_v1',
    'list_services_v1',
  ]],
  [migration('20260906008500_enable_non_inventory_services.sql'), [
    'SET services=true',
    'revision=revision+1',
  ]],
  [migration('20260906009500_gre_service_cargo_guard.sql'), [
    'es_servicio',
    'guias_remision_detalles',
  ]],

  // Métricas: catálogo cerrado, nunca fórmulas/SQL del usuario.
  [migration('20260906009000_configurable_business_metrics.sql'), [
    'business_metric_definitions',
    'source_key text NOT NULL CHECK',
    'list_business_metrics_v1',
    'save_business_metrics_v1',
    'reports.view_profit',
  ]],

  [mobile('features', 'shared', 'widgets', 'product_quantity_dialog.dart'), [
    '_product.commercialProfile',
    'presentation.baseQuantity',
    'PriceSaleLineUseCase',
  ]],
  [mobile('features', 'Cotizar', 'pages', 'nueva_cotizacion_page.dart'), [
    'ProductQuantityDialog',
    'aplicarRestriccionStock: false',
  ]],
  [core('features', 'ventas', 'data', 'quotation_sale_cart_mapper.dart'), [
    'presentation_snapshot',
    'unit_configuration',
    'unit_profile_revision',
    'commercial_unit_label',
    'stock_scale',
  ]],
  [core('features', 'almacen', 'domain', 'product_unit_configuration.dart'), [
    'PresentationPolicy',
    'DiscretePresentationPolicy',
    'storageScale',
    'toStoredBaseQuantity',
    'fromStoredBaseQuantity',
  ]],
  [core('features', 'almacen', 'domain', 'quantity.dart'), [
    'class FixedQuantity',
    'minorUnits',
    'scale',
    'maxScale',
  ]],
  [core('features', 'ventas', 'application', 'sale_processing_models.dart'), [
    'storedBaseQuantity',
    'storageScale',
    'double quantity',
    'double baseQuantity',
  ]],
  [core('features', 'almacen', 'data', 'supabase_product_unit_configuration_gateway.dart'), [
    'save_product_unit_profile_v6',
    'PresentationPolicy.validate(profile)',
    'ProductUnitConfigurationMapper.encodeProfile(profile)',
  ]],
  [core('features', 'almacen', 'application', 'save_product_unit_configuration_use_case.dart'), [
    'PresentationPolicy.validate(profile)',
  ]],
  [core('auth', 'domain', 'session_authorization.dart'), [
    'Set<AppPermission> permissions',
    'CachedSessionAuthorization',
  ]],
  [core('auth', 'application', 'operation_authorizer.dart'), [
    'result.permissions.containsAll(permissions)',
  ]],
  [core('features', 'trazabilidad', 'application', 'inventory_traceability_use_case.dart'), [
    'InventoryTraceabilityGateway',
    'InventoryTraceabilityUseCase',
    'lotTracking',
    'expiryTracking',
    'serialNumberTracking',
    'AppPermission.inventoryReceive',
  ]],
  [core('features', 'servicios', 'application', 'service_catalog_use_case.dart'), [
    'ServiceCatalogGateway',
    'ServiceCatalogUseCase',
    'profile.capabilities.services',
    'AppPermission.productsChangePrice',
  ]],
  [core('features', 'reportes', 'application', 'configurable_metrics_use_case.dart'), [
    'ConfigurableMetricGateway',
    'ConfigurableMetricsUseCase',
    'MetricSource.salesCount',
    'movement.entryQuantity > 0 || movement.isEntry',
    'movement.exitQuantity > 0 || !movement.isEntry',
  ]],
  [mobile('features', 'trazabilidad', 'pages', 'trazabilidad_config_page.dart'), [
    'updateBusinessCapabilitiesUseCaseProvider',
    'lotTracking',
    'serialNumberTracking',
  ]],
  [desktop('features', 'traceability', 'desktop_traceability_config_panel.dart'), [
    'updateBusinessCapabilitiesUseCaseProvider',
    'lotTracking',
    'serialNumberTracking',
  ]],
  [mobile('features', 'servicios', 'pages', 'servicios_page.dart'), [
    'serviceCatalogUseCaseProvider',
  ]],
  [desktop('features', 'services', 'desktop_services_panel.dart'), [
    'serviceCatalogUseCaseProvider',
  ]],
  [mobile('features', 'metricas', 'pages', 'metricas_configurables_page.dart'), [
    'configurableMetricsUseCaseProvider',
    'Mes actual',
  ]],
  [desktop('features', 'metrics', 'desktop_metrics_panel.dart'), [
    'configurableMetricsUseCaseProvider',
    'DesktopMetricsPanel',
  ]],
  [mobile('home', 'home_page.dart'), [
    "'metrics' => const MetricasConfigurablesPage()",
  ]],
  [desktop('features', 'home', 'desktop_home_shell.dart'), [
    'DesktopMetricsPanel',
    "ValueKey('metrics')",
  ]],
]) {
  contract(path, requirements);
}

if (existsSync(unitMigration)) {
  const source = readFileSync(unitMigration, 'utf8');
  if (!source.includes("'base_label', v_base_label")) {
    error(unitMigration, 'el snapshot debe usar la etiqueta base del perfil persistido');
  }
  if (source.includes("'base_label', v_detail->>")) {
    error(unitMigration, 'el snapshot no puede confiar en una etiqueta enviada por el cliente');
  }
  if (!source.includes(
    'REVOKE ALL ON FUNCTION public._validate_product_unit_profile(jsonb) FROM PUBLIC, anon, authenticated;',
  )) {
    error(unitMigration, 'el validador interno no debe ser invocable por clientes');
  }
}

if (existsSync(immutableScaleMigration)) {
  const source = readFileSync(immutableScaleMigration, 'utf8');
  if (/UPDATE\s+public\.detalle_(?:ventas|cotizaciones)/i.test(source)) {
    error(immutableScaleMigration, 'el writer final no debe reescribir historial comercial');
  }
}

if (errors.length) {
  console.error(errors.join('\n'));
  console.error(`${errors.length} problemas en ${checked} archivos Dart.`);
  process.exitCode = 1;
} else {
  console.log(`OK: ${checked} archivos Dart; imports, capas y contratos funcionales.`);
  console.log(`OK: ${migrationVersions.size} versiones Supabase únicas.`);
  console.log(
    'Pendiente por separado: dart format, flutter analyze, flutter test, SQL local y smoke builds.',
  );
}
