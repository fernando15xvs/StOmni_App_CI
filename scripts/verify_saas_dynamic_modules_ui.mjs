import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = {
  policy: 'packages/core_logic/lib/business/application/business_module_policy.dart',
  policyTest: 'packages/core_logic/test/business/business_module_policy_test.dart',
  desktopShell: 'packages/desktop_app/lib/features/home/desktop_home_shell.dart',
  desktopSettings: 'packages/desktop_app/lib/features/settings/desktop_business_modules_panel.dart',
  mobileHome: 'packages/mobile_app/lib/home/home_page.dart',
  mobileNav: 'packages/mobile_app/lib/home/widgets/custom_bottom_nav.dart',
  mobileSettings: 'packages/mobile_app/lib/features/configuracion/pages/modulos_negocio_page.dart',
};

const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const need = (errors, source, regex, label) => {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
};

function verify(sources) {
  const errors = [];
  const { policy, policyTest, desktopShell, desktopSettings, mobileHome, mobileNav, mobileSettings } = sources;

  need(errors, policy, /enum BusinessModule[\s\S]{0,800}?moduleSettings/i, 'BusinessModule.moduleSettings estable');
  need(errors, policy, /BusinessModule\.services\s*=>\s*c\.services/i, 'Servicios depende de capability');
  need(errors, policy, /BusinessModule\.variants\s*=>\s*c\.variants/i, 'Variantes depende de capability');
  need(errors, policy, /BusinessModule\.inventory\s*\|\|\s*BusinessModule\.stockTransfers\s*=>\s*c\.inventoryEnabled/i, 'Inventario/movimientos dependen de inventoryEnabled');
  need(errors, policy, /BusinessModule\.purchases\s*=>\s*c\.purchaseManagement/i, 'Compras depende de purchaseManagement');
  need(errors, policy, /BusinessModule\.electronicDocuments\s*=>\s*c\.electronicInvoicing/i, 'Facturación depende de electronicInvoicing');
  need(errors, policy, /BusinessModule\.moduleSettings[\s\S]{0,120}?=>\s*true/i, 'Configuración de módulos permanece alcanzable');

  need(errors, desktopShell, /BusinessModule _selectedModule\s*=\s*BusinessModule\.dashboard/i, 'desktop selecciona por clave de módulo, no índice persistente');
  need(errors, desktopShell, /BusinessModulePolicy\.isEnabled\(/i, 'desktop usa política compartida');
  need(errors, desktopShell, /destinations\.indexWhere[\s\S]{0,160}?destination\.module\s*==\s*_selectedModule/i, 'desktop deriva índice desde clave estable');
  need(errors, desktopShell, /DesktopBusinessModulesPanel[\s\S]{0,240}?onProfileSaved/i, 'desktop configuración notifica perfil guardado');
  need(errors, desktopShell, /_businessProfile\s*=\s*profile/i, 'desktop refresca perfil sin reiniciar sesión');

  need(errors, desktopSettings, /updateBusinessCapabilitiesUseCaseProvider/i, 'desktop configura capacidades vía use case');
  need(errors, desktopSettings, /purchaseManagement:\s*inventory\s*\?/i, 'desktop apaga compras al apagar inventario');
  need(errors, desktopSettings, /multipleWarehouses:\s*[\s\S]{0,80}?inventory\s*\?/i, 'desktop apaga multi-almacén al apagar inventario');
  need(errors, desktopSettings, /widget\.onProfileSaved\?\.call\(saved\)/i, 'desktop propaga perfil guardado');

  need(errors, mobileHome, /BusinessModulePolicy\.isEnabled\(/i, 'mobile gestión usa política compartida');
  need(errors, mobileHome, /'modules'\s*=>\s*const ModulosNegocioPage\(\)/i, 'mobile mantiene configuración de módulos alcanzable');
  need(errors, mobileHome, /if \(destination == 'modules'\) await _loadBusinessProfile\(\)/i, 'mobile refresca perfil al volver de configuración');
  need(errors, mobileHome, /if \(!profile\.capabilities\.inventoryEnabled\s*&&\s*\(current == 2 \|\| current == 4\)\)[\s\S]{0,130}?state = 0/i, 'mobile expulsa inventario y traslados cuando inventoryEnabled=false');
  need(errors, mobileHome, /inventoryEnabled:\s*inventoryEnabled/i, 'mobile propaga inventoryEnabled a navegación principal');

  need(errors, mobileNav, /final bool inventoryEnabled;/i, 'bottom nav recibe capability de inventario');
  need(errors, mobileNav, /final items = \[/i, 'bottom nav mantiene colección dinámica');
  need(errors, mobileNav, /const _NavItem\(0,[\s\S]{0,80}?'Inicio'\)/i, 'bottom nav Inicio estable');
  need(errors, mobileNav, /const _NavItem\(1,[\s\S]{0,100}?'Balance'\)/i, 'bottom nav Balance estable');
  need(errors, mobileNav, /if \(inventoryEnabled\)\s*const _NavItem\(2,[\s\S]{0,100}?'Inventario'\)/i, 'bottom nav oculta inventario sin capability');
  need(errors, mobileNav, /const _NavItem\(3,[\s\S]{0,100}?'Centro'\)/i, 'bottom nav incluye Centro disponible');
  need(errors, mobileNav, /if \(inventoryEnabled\)\s*const _NavItem\(4,[\s\S]{0,100}?'Movimientos'\)/i, 'bottom nav oculta traslados sin inventario');
  need(errors, mobileNav, /homeTabProvider\.notifier\)\.state\s*=\s*item\.index/i, 'navigation usa clave estable, no posición visible');
  need(errors, mobileNav, /for \(final item in items\)/i, 'render usa tabs visibles');

  need(errors, mobileSettings, /updateBusinessCapabilitiesUseCaseProvider/i, 'mobile configura capacidades vía use case');
  need(errors, mobileSettings, /purchaseManagement:\s*inventory\s*\?/i, 'mobile apaga compras al apagar inventario');
  need(errors, mobileSettings, /Módulos del negocio/i, 'mobile pantalla de módulos existe');

  need(errors, policyTest, /optional modules follow capabilities/i, 'test módulos opcionales');
  need(errors, policyTest, /core modules stay available/i, 'test módulos core');
  need(errors, policyTest, /moduleSettings/i, 'test vía de recuperación de configuración');

  if (/switch\s*\(_selectedIndex\)/i.test(desktopShell)) {
    errors.push('Desktop no debe volver a mapear módulos por índices posicionales fijos.');
  }
  if (/width\s*\/\s*4[\s\S]{0,180}?clamp\(0,\s*3\)/i.test(mobileNav)) {
    errors.push('Bottom nav no debe conservar hit-testing fijo de cuatro tabs cuando inventario puede ocultarse.');
  }
  return errors;
}

function sources() {
  return Object.fromEntries(Object.entries(files).map(([key, value]) => [key, read(value)]));
}

function selfTest() {
  const base = sources();
  const cases = [
    ['válido', base, false],
    ['desktop índice fijo', { ...base, desktopShell: `${base.desktopShell}\nswitch (_selectedIndex) {}` }, true],
    ['mobile sin política', { ...base, mobileHome: base.mobileHome.replaceAll('BusinessModulePolicy.isEnabled', 'removedPolicy') }, true],
    ['nav cuatro tabs fijo', { ...base, mobileNav: `${base.mobileNav}\nfinal tabWidth = width / 4; final x = 0.clamp(0, 3);` }, true],
    ['nav sin capacidad', { ...base, mobileNav: base.mobileNav.replaceAll('if (inventoryEnabled)', 'if (true)') }, true],
    ['nav sin centro', { ...base, mobileNav: base.mobileNav.replaceAll("'Centro'", "'Otro'") }, true],
    ['sin settings estable', { ...base, policy: base.policy.replaceAll('BusinessModule.moduleSettings', 'BusinessModule.dashboard') }, true],
  ];
  const failed = [];
  for (const [name, candidate, shouldFail] of cases) {
    const didFail = verify(candidate).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS dynamic modules UI self-test FAILED:');
    for (const name of failed) console.error(`  - ${name}`);
    process.exit(1);
  }
  console.log(`SaaS dynamic modules UI self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(sources());
if (errors.length) {
  console.error('SaaS dynamic modules UI gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS dynamic modules UI gate OK (F5.4).');
