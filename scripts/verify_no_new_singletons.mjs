import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..');

const MIGRATION_BASELINE = '20260907003926_storage_buckets_and_policies.sql';
const LEGACY_SQL_EXCEPTION = '-- saas-legacy-singleton-exception: legacy-backfill';

// F3.7 documenta estas tres superficies como deuda sintáctica congelada.
// No son autoridad de tenant: Flutter queda detrás de RLS y los helpers Edge
// usan un cliente service_role tenant-scoped. El hash impide que la deuda crezca.
const LEGACY_RUNTIME_FILES = new Map([
  ['packages/core_logic/lib/features/facturacion/data/guias_remision_repository.dart', 'c0800d1d7478da0965502cc1886541afc1f59401'],
  ['supabase/functions/_shared/proceso_tributario_common.ts', 'daedc9e7027f07ec25af3f4f4f12c31bdcd6315b'],
  ['supabase/functions/_shared/guia_remision_common.ts', 'bdd2b6d7a2c5ea46391e892952cf8c819ae61706'],
]);

const RUNTIME_PATTERNS = [
  {
    id: 'business-id-literal',
    regex: /\bbusinessId\s*(?::|=|==|!=|===|!==)\s*['"]1['"]/g,
  },
  {
    id: 'legacy-business-id-constant',
    regex: /legacyWritableBusinessId\s*=\s*['"]1['"]/g,
  },
  {
    id: 'business-id-fallback-to-one',
    regex: /\bbusinessId\s*:\s*_text\(\s*raw\[['"]id['"]\]\s*,\s*fallback:\s*['"]1['"]\s*\)/g,
  },
  {
    id: 'business-row-id-must-be-one',
    regex: /\bbusiness_id\b[\s\S]{0,220}?\bid\s*(?:==|!=|===|!==)\s*['"]1['"]/g,
  },
  {
    id: 'config-table-id-one',
    regex: /\.from\(\s*['"]configuracion_negocio['"]\s*\)[\s\S]{0,400}?\.eq\(\s*['"]id['"]\s*,\s*1\s*\)/g,
  },
  {
    id: 'config-table-first-row',
    regex: /\.from\(\s*['"]configuracion_negocio['"]\s*\)[\s\S]{0,400}?\.order\(\s*['"]id['"]\s*\)[\s\S]{0,140}?\.limit\(\s*1\s*\)/g,
  },
  {
    id: 'business-profile-cache-one',
    regex: /business_profile[^'"\n]*:1['"]/g,
  },
  {
    id: 'business-id-column-one',
    regex: /(?:['"]business_id['"]|\bbusiness_id\b)[\s\S]{0,100}?(?:==|===|=)\s*1\b/g,
  },
];

const SQL_PATTERNS = [
  {
    id: 'sql-business-id-one',
    regex: /\bbusiness_id\s*=\s*1\b/gi,
  },
  {
    id: 'sql-config-id-one',
    regex: /\bconfiguracion_negocio\b[\s\S]{0,900}?\bwhere\s+(?:[a-z_][a-z0-9_]*\.)?id\s*=\s*1\b/gi,
  },
  {
    id: 'sql-config-first-row',
    regex: /\bconfiguracion_negocio\b[\s\S]{0,900}?\border\s+by\s+(?:[a-z_][a-z0-9_]*\.)?id\b[\s\S]{0,180}?\blimit\s+1\b/gi,
    ignore: (sample) =>
      /(?:\b[a-z_][a-z0-9_]*\.)?organization_id\s*=\s*private\.require_current_organization_id\(\)/i.test(
        sample,
      ),
  },
  {
    id: 'sql-business-id-references-config-singleton-model',
    regex: /(?:\bbusiness_id\b[^,;\n]{0,120}?\breferences\s+public\.configuracion_negocio\s*\(\s*id\s*\)|\bforeign\s+key\s*\(\s*business_id\s*\)\s*references\s+public\.configuracion_negocio\s*\(\s*id\s*\))/gi,
  },
];

function normalizeGitText(content) {
  return content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

function gitBlobSha(content) {
  const normalized = normalizeGitText(content);
  const bytes = Buffer.byteLength(normalized);
  return createHash('sha1')
    .update(`blob ${bytes}\0`)
    .update(normalized)
    .digest('hex');
}

function lineNumber(content, index) {
  return content.slice(0, index).split('\n').length;
}

function collectMatches(content, patterns) {
  const matches = [];
  for (const { id, regex, ignore } of patterns) {
    regex.lastIndex = 0;
    for (const match of content.matchAll(regex)) {
      const raw = String(match[0]);
      if (ignore?.(raw)) continue;
      matches.push({
        id,
        line: lineNumber(content, match.index ?? 0),
        sample: raw.replace(/\s+/g, ' ').slice(0, 180),
      });
    }
  }
  return matches;
}

function maskPreserveLines(value) {
  return value.replace(/[^\n]/g, ' ');
}

function prepareSqlForScan(content) {
  let executable = normalizeGitText(content);

  // Comentarios no forman parte del SQL ejecutable para este gate.
  executable = executable.replace(/--.*$/gm, (value) => maskPreserveLines(value));

  // Las migraciones de hardening usan v_old como texto de búsqueda para
  // reemplazar implementaciones legacy. Ese literal no se ejecuta como SQL.
  executable = executable.replace(
    /\bv_old\s*:=\s*E?'(?:''|\\.|[^'])*'\s*;/gsi,
    (value) => maskPreserveLines(value),
  );

  return executable;
}

function isFailClosedLegacyBackfill(content, match) {
  if (match.id !== 'sql-config-first-row') return false;
  const normalized = normalizeGitText(content);
  return (
    /count\s*\(\s*DISTINCT\s+organization_id\s*\)/i.test(normalized) &&
    /IF\s+v_organization_count\s*<>\s*1\s+THEN/i.test(normalized) &&
    /RAISE\s+EXCEPTION/i.test(normalized) &&
    /Ambiguous legacy state/i.test(normalized)
  );
}

function walkFiles(root) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      if (['.dart_tool', 'build', 'coverage', 'node_modules'].includes(entry.name)) continue;
      files.push(...walkFiles(full));
      continue;
    }
    if (entry.isFile()) files.push(full);
  }
  return files;
}

function relative(file) {
  return path.relative(repoRoot, file).replaceAll(path.sep, '/');
}

function isRuntimeSource(rel) {
  if (!/\.(dart|ts|js|mjs)$/.test(rel)) return false;
  if (/\.(g|freezed)\.dart$/.test(rel)) return false;
  if (/^supabase\/functions\//.test(rel)) return true;
  return /^(apps|packages)\/[^/]+\/lib\//.test(rel);
}

function formatMatch(rel, match) {
  return `  - ${rel}:${match.line} [${match.id}] ${match.sample}`;
}

function runSelfTest() {
  const cases = [
    {
      name: 'detecta businessId literal',
      content: "const x = BusinessProfile(businessId: '1');",
      patterns: RUNTIME_PATTERNS,
      expected: true,
    },
    {
      name: 'detecta configuracion primera fila',
      content: ".from('configuracion_negocio').select().order('id').limit(1).single()",
      patterns: RUNTIME_PATTERNS,
      expected: true,
    },
    {
      name: 'detecta SQL business_id = 1',
      content: 'UPDATE public.business_capabilities SET revision=2 WHERE business_id = 1;',
      patterns: SQL_PATTERNS,
      expected: true,
      sql: true,
    },
    {
      name: 'detecta FK legacy business_id sin tenant',
      content: 'business_id bigint REFERENCES public.configuracion_negocio(id)',
      patterns: SQL_PATTERNS,
      expected: true,
      sql: true,
    },
    {
      name: 'acepta FK compuesta tenant-qualified',
      content: 'FOREIGN KEY (organization_id, business_id) REFERENCES public.configuracion_negocio(organization_id, id)',
      patterns: SQL_PATTERNS,
      expected: false,
      sql: true,
    },
    {
      name: 'ignora literal 1 ajeno al tenant',
      content: "DropdownMenuItem(value: '1', child: Text('DNI'))",
      patterns: RUNTIME_PATTERNS,
      expected: false,
    },
    {
      name: 'acepta organization_id real',
      content: "query.eq('organization_id', organizationId)",
      patterns: RUNTIME_PATTERNS,
      expected: false,
    },
    {
      name: 'acepta configuracion tenant-scoped con limit 1',
      content:
        'FROM public.configuracion_negocio AS cn WHERE cn.organization_id = private.require_current_organization_id() ORDER BY cn.id LIMIT 1;',
      patterns: SQL_PATTERNS,
      expected: false,
      sql: true,
    },
    {
      name: 'ignora v_old usado sólo como patrón de parche',
      content:
        "v_old:=E'FROM public.configuracion_negocio AS cn\\n ORDER BY cn.id\\n LIMIT 1;';\n" +
        "v_new:=E'FROM public.configuracion_negocio AS cn\\n WHERE cn.organization_id = private.require_current_organization_id()\\n ORDER BY cn.id\\n LIMIT 1;';",
      patterns: SQL_PATTERNS,
      expected: false,
      sql: true,
    },
  ];

  const failed = [];
  for (const testCase of cases) {
    const source = testCase.sql ? prepareSqlForScan(testCase.content) : testCase.content;
    const detected = collectMatches(source, testCase.patterns).length > 0;
    if (detected !== testCase.expected) failed.push(testCase.name);
  }

  const commented = '-- business_id = 1 es deuda histórica documentada\nSELECT 1;';
  if (collectMatches(prepareSqlForScan(commented), SQL_PATTERNS).length > 0) {
    failed.push('ignora singleton mencionado sólo en comentario SQL');
  }

  if (gitBlobSha('uno\r\ndos\r\n') !== gitBlobSha('uno\ndos\n')) {
    failed.push('baseline SHA es estable entre CRLF y LF');
  }

  const backfill = `
    SELECT count(DISTINCT organization_id)::integer
    INTO v_organization_count
    FROM public.configuracion_negocio;
    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION 'Ambiguous legacy state';
    END IF;
    SELECT organization_id FROM public.configuracion_negocio ORDER BY id LIMIT 1;
  `;
  const backfillMatches = collectMatches(prepareSqlForScan(backfill), SQL_PATTERNS);
  if (
    backfillMatches.length !== 1 ||
    !isFailClosedLegacyBackfill(backfill, backfillMatches[0])
  ) {
    failed.push('acepta sólo backfill legacy fail-closed con una organización');
  }

  if (failed.length > 0) {
    console.error('Anti-singleton self-test FAILED:');
    for (const name of failed) console.error(`  - ${name}`);
    process.exit(1);
  }

  console.log(`Anti-singleton self-test OK (${cases.length + 3} casos).`);
}

function main() {
  if (process.argv.includes('--self-test')) {
    runSelfTest();
    return;
  }

  const errors = [];
  const warnings = [];
  let runtimeScanned = 0;
  let legacyRuntimeAccepted = 0;
  let newMigrationsScanned = 0;

  const runtimeRoots = [
    path.join(repoRoot, 'apps'),
    path.join(repoRoot, 'packages'),
    path.join(repoRoot, 'supabase', 'functions'),
  ];

  const runtimeFiles = runtimeRoots
    .flatMap(walkFiles)
    .filter((file) => isRuntimeSource(relative(file)));

  for (const file of runtimeFiles) {
    const rel = relative(file);
    const content = fs.readFileSync(file, 'utf8');
    const matches = collectMatches(content, RUNTIME_PATTERNS);
    runtimeScanned += 1;
    if (matches.length === 0) continue;

    const expectedSha = LEGACY_RUNTIME_FILES.get(rel);
    if (!expectedSha) {
      errors.push(`Nuevo singleton tenant en código ejecutable: ${rel}`);
      errors.push(...matches.map((match) => formatMatch(rel, match)));
      continue;
    }

    const actualSha = gitBlobSha(content);
    if (actualSha !== expectedSha) {
      errors.push(
        `Archivo legacy con singleton fue modificado sin eliminar toda la dependencia: ${rel}`,
      );
      errors.push(`  - SHA baseline: ${expectedSha}`);
      errors.push(`  - SHA actual:   ${actualSha}`);
      errors.push(...matches.map((match) => formatMatch(rel, match)));
      continue;
    }

    legacyRuntimeAccepted += 1;
  }

  for (const [rel] of LEGACY_RUNTIME_FILES) {
    const file = path.join(repoRoot, rel);
    if (!fs.existsSync(file)) continue;
    const content = fs.readFileSync(file, 'utf8');
    if (collectMatches(content, RUNTIME_PATTERNS).length === 0) {
      warnings.push(`Baseline legacy ya limpio; retirar entrada: ${rel}`);
    }
  }

  const migrationsDir = path.join(repoRoot, 'supabase', 'migrations');
  const migrationFiles = walkFiles(migrationsDir)
    .filter((file) => relative(file).match(/^supabase\/migrations\/[^/]+\.sql$/))
    .sort((a, b) => path.basename(a).localeCompare(path.basename(b)));

  for (const file of migrationFiles) {
    const name = path.basename(file);
    if (name <= MIGRATION_BASELINE) continue;
    newMigrationsScanned += 1;

    const content = fs.readFileSync(file, 'utf8');
    const executable = prepareSqlForScan(content);
    const matches = collectMatches(executable, SQL_PATTERNS);
    if (matches.length === 0) continue;

    if (content.includes(LEGACY_SQL_EXCEPTION)) {
      warnings.push(
        `Excepción legacy-backfill usada en ${relative(file)}; debe desaparecer al cerrar la migración singleton.`,
      );
      continue;
    }

    const acceptedBackfill = matches.filter((match) =>
      isFailClosedLegacyBackfill(content, match),
    );
    const blocking = matches.filter(
      (match) => !isFailClosedLegacyBackfill(content, match),
    );

    if (acceptedBackfill.length > 0) {
      warnings.push(
        `Backfill legacy fail-closed reconocido en ${relative(file)} (${acceptedBackfill.length} coincidencia(s)); exige exactamente una organización y aborta estados ambiguos.`,
      );
    }

    if (blocking.length === 0) continue;

    errors.push(`Nueva migración reintroduce el modelo singleton: ${relative(file)}`);
    errors.push(...blocking.map((match) => formatMatch(relative(file), match)));
  }

  if (warnings.length > 0) {
    console.warn('Anti-singleton warnings:');
    for (const warning of warnings) console.warn(`  - ${warning}`);
  }

  if (errors.length > 0) {
    console.error('Anti-singleton gate FAILED:');
    for (const error of errors) console.error(error);
    console.error('\nNo añadas otra empresa fija. Resuelve organization_id desde el contexto autenticado.');
    process.exit(1);
  }

  console.log('Anti-singleton gate OK.');
  console.log(`  Runtime files scanned: ${runtimeScanned}`);
  console.log(`  Legacy runtime singletons accepted: ${legacyRuntimeAccepted}/${LEGACY_RUNTIME_FILES.size}`);
  console.log(`  New migrations scanned after baseline: ${newMigrationsScanned}`);
  console.log(`  Migration baseline: ${MIGRATION_BASELINE}`);
}

main();
