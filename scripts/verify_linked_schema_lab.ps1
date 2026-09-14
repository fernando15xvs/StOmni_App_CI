[CmdletBinding()]
param(
  [switch]$KeepLab
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$migrationsDir = Join-Path $repoRoot 'supabase/migrations'
$testsDir = Join-Path $repoRoot 'supabase/tests/database'

function Assert-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "No se encontro '$Name' en PATH."
  }
}

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ''
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-CapturedSupabase {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$LogPath
  )

  $previous = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & supabase @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previous
  }

  $lines = @($output | ForEach-Object { $_.ToString() })
  if ($LogPath) {
    $lines | Set-Content -Encoding UTF8 -LiteralPath $LogPath
  }
  $lines | ForEach-Object { Write-Host $_ }

  if ($exitCode -ne 0) {
    throw "Supabase termino con codigo ${exitCode}: supabase $($Arguments -join ' ')"
  }
  return $lines
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor DarkCyan
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "El comando fallo con codigo ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
  }
}

function Invoke-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$ContainerId,
    [Parameter(Mandatory = $true)][string]$SqlPath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -LiteralPath $SqlPath -PathType Leaf)) {
    throw "No existe el SQL requerido para ${Label}: $SqlPath"
  }

  Write-Step $Label
  Write-Host "Archivo: $SqlPath" -ForegroundColor DarkGray
  $previousEncoding = $OutputEncoding
  try {
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    Get-Content -LiteralPath $SqlPath -Raw -Encoding UTF8 |
      & docker exec -i $ContainerId psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres
    $exitCode = $LASTEXITCODE
  }
  finally {
    $OutputEncoding = $previousEncoding
  }

  if ($exitCode -ne 0) {
    throw "psql fallo con codigo ${exitCode} al ejecutar: $SqlPath"
  }
}

Assert-Command supabase
Assert-Command docker

if (-not (Test-Path -LiteralPath $migrationsDir -PathType Container)) {
  throw "No existe el directorio de migraciones: $migrationsDir"
}
if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
  throw "No existe el directorio de pruebas SQL: $testsDir"
}

$labRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stomni-linked-schema-lab-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
$snapshotPath = Join-Path $labRoot 'linked_public_schema.sql'
$migrationListLog = Join-Path $labRoot 'migration_list.txt'
$dbContainer = $null
$labStarted = $false

Push-Location -LiteralPath $repoRoot
try {
  Write-Host 'StOmni - laboratorio SQL local desde snapshot remoto SOLO LECTURA' -ForegroundColor Green
  Write-Host 'No usa db push, migration repair ni db reset --linked.' -ForegroundColor Yellow

  Write-Step 'Leyendo historial de migraciones del proyecto vinculado'
  $migrationLines = Invoke-CapturedSupabase -Arguments @('migration', 'list', '--linked') -LogPath $migrationListLog

  # La salida real de Supabase usa | como separador de columnas. Extraemos
  # EXCLUSIVAMENTE la segunda columna (Remote). Nunca inferimos una version
  # remota desde Local ni desde Time, porque Time puede contener otro timestamp.
  $remoteVersions = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($line in $migrationLines) {
    $clean = $line -replace '\x1b\[[0-9;]*m', ''
    if (-not $clean.Contains('|')) { continue }
    $parts = @($clean -split '\|')
    if ($parts.Count -lt 3) { continue }
    $remote = ($parts[1] -replace '[^0-9]', '')
    if ($remote -match '^\d{14}$') {
      [void]$remoteVersions.Add($remote)
    }
  }

  if ($remoteVersions.Count -eq 0) {
    throw (
      'No se pudo resolver ningun timestamp de la columna Remote. ' +
      'No se aplicara ninguna migracion por seguridad.'
    )
  }

  $remoteMax = @($remoteVersions | Sort-Object | Select-Object -Last 1)[0]
  Write-Host "Ultima version registrada en remoto: $remoteMax" -ForegroundColor Green

  $localMigrations = @(
    Get-ChildItem -LiteralPath $migrationsDir -File -Filter '*.sql' |
      Where-Object { $_.Name -match '^(\d{14})_.+\.sql$' } |
      Sort-Object Name
  )

  # El ledger remoto puede contener versiones posteriores que no existen en Git
  # (por ejemplo migraciones out-of-band generadas por otro flujo). Por eso NO
  # usamos remoteMax como frontera de pendientes. La frontera segura es la ultima
  # version que existe tanto en Git como en el ledger remoto: el snapshot ya
  # contiene todo lo aplicado hasta esa ancla comun. A partir de ahi probamos en
  # el laboratorio cada migracion local ausente del ledger remoto.
  $localVersions = New-Object 'System.Collections.Generic.HashSet[string]'
  $commonVersions = @()
  foreach ($file in $localMigrations) {
    $version = [regex]::Match($file.Name, '^(\d{14})_').Groups[1].Value
    [void]$localVersions.Add($version)
    if ($remoteVersions.Contains($version)) {
      $commonVersions += $version
    }
  }

  if ($commonVersions.Count -eq 0) {
    throw (
      'No existe ninguna version comun entre Git y el ledger remoto. ' +
      'No se aplicara ninguna migracion por seguridad.'
    )
  }

  $baselineAnchor = @($commonVersions | Sort-Object | Select-Object -Last 1)[0]
  Write-Host "Ancla comun Git/remoto para el snapshot: $baselineAnchor" -ForegroundColor Green

  $remoteOnlyAfterAnchor = @(
    $remoteVersions |
      Where-Object {
        [string]::CompareOrdinal($_, $baselineAnchor) -gt 0 -and
        -not $localVersions.Contains($_)
      } |
      Sort-Object
  )
  if ($remoteOnlyAfterAnchor.Count -gt 0) {
    Write-Host ''
    Write-Host 'Versiones remotas posteriores al ancla sin archivo local (solo diagnostico):' -ForegroundColor DarkYellow
    $remoteOnlyAfterAnchor | ForEach-Object { Write-Host "  remote-only: $_" -ForegroundColor DarkYellow }
  }

  $pending = @()
  $historicalLocalOnly = @()
  foreach ($file in $localMigrations) {
    $version = [regex]::Match($file.Name, '^(\d{14})_').Groups[1].Value
    if (-not $remoteVersions.Contains($version)) {
      if ([string]::CompareOrdinal($version, $baselineAnchor) -gt 0) {
        $pending += $file
      }
      else {
        $historicalLocalOnly += $file
      }
    }
  }

  if ($historicalLocalOnly.Count -gt 0) {
    Write-Host ''
    Write-Host 'Migraciones locales historicas ausentes del ledger remoto (solo diagnostico; no se reaplican):' -ForegroundColor DarkYellow
    $historicalLocalOnly | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor DarkYellow }
  }

  Write-Host ''
  if ($pending.Count -eq 0) {
    Write-Host 'No hay migraciones locales pendientes despues del ancla comun.' -ForegroundColor Yellow
  }
  else {
    Write-Host "Migraciones pendientes que se probaran SOLO EN EL LAB: $($pending.Count)" -ForegroundColor Green
    $pending | ForEach-Object { Write-Host "  + $($_.Name)" }
  }

  Write-Step 'Exportando esquema public actual del proyecto vinculado (solo lectura)'
  Invoke-CapturedSupabase -Arguments @(
    'db', 'dump', '--linked', '--schema', 'public', '-f', $snapshotPath
  ) | Out-Null

  if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
    throw 'Supabase no genero el snapshot public esperado.'
  }
  $snapshotSize = (Get-Item -LiteralPath $snapshotPath).Length
  if ($snapshotSize -lt 100000) {
    throw "El snapshot public parece incompleto ($snapshotSize bytes)."
  }
  $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
  Write-Host "Snapshot: $snapshotSize bytes / SHA256 $snapshotHash" -ForegroundColor Green

  $existingDbContainers = @(
    & docker ps --filter 'name=supabase_db_' --format '{{.ID}}|{{.Names}}'
  )
  if ($LASTEXITCODE -ne 0) {
    throw 'No se pudieron consultar los contenedores Docker actuales.'
  }
  if ($existingDbContainers.Count -gt 0) {
    throw (
      'Ya existe una base Supabase local ejecutandose. Detenla antes de abrir el laboratorio: ' +
      ($existingDbContainers -join ', ')
    )
  }

  Push-Location -LiteralPath $labRoot
  try {
    Write-Step 'Inicializando proyecto Supabase temporal aislado'
    Invoke-Checked -Command 'supabase' -Arguments @('init')

    Write-Step 'Iniciando solo Postgres para el laboratorio'
    Invoke-Checked -Command 'supabase' -Arguments @('db', 'start')
    $labStarted = $true

    $dbContainers = @(
      & docker ps --filter 'name=supabase_db_' --format '{{.ID}}|{{.Names}}'
    )
    if ($LASTEXITCODE -ne 0) {
      throw 'No se pudo localizar el Postgres Docker del laboratorio.'
    }
    if ($dbContainers.Count -ne 1) {
      throw "Se esperaba exactamente un contenedor supabase_db_ y se encontraron $($dbContainers.Count)."
    }
    $dbContainer = ($dbContainers[0] -split '\|', 2)[0]
    if (-not $dbContainer) {
      throw 'No se pudo resolver el ID del contenedor Postgres del laboratorio.'
    }

    # Supabase local puede traer default privileges permisivos para
    # anon/authenticated y PostgreSQL concede EXECUTE a PUBLIC en funciones
    # nuevas. pg_dump no siempre representa esos defaults antes de recrear
    # objetos, por lo que los neutralizamos antes de restaurar el snapshot.
    $restoreDefaultsPath = Join-Path $labRoot 'normalize_local_restore_defaults.sql'
    @"
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated;
"@ | Set-Content -Encoding UTF8 -LiteralPath $restoreDefaultsPath

    Invoke-PsqlFile `
      -ContainerId $dbContainer `
      -SqlPath $restoreDefaultsPath `
      -Label 'Neutralizando default privileges del laboratorio LOCAL'

    Invoke-PsqlFile -ContainerId $dbContainer -SqlPath $snapshotPath -Label 'Restaurando snapshot public remoto en LOCAL'

    foreach ($migration in $pending) {
      Invoke-PsqlFile -ContainerId $dbContainer -SqlPath $migration.FullName -Label (
        'Aplicando SOLO EN LOCAL: ' + $migration.Name
      )
    }

    $labTestsDir = Join-Path $labRoot 'supabase/tests/database'
    New-Item -ItemType Directory -Path $labTestsDir -Force | Out-Null

    # Los fingerprints de Fase 5 fijan conteos exactos de un snapshot historico
    # (44 tablas, 74 funciones, etc.). No pertenecen al gate del esquema actual,
    # porque los modulos posteriores aumentan esos conteos deliberadamente.
    $historicalFingerprintTests = @(
      'fase5_production_fingerprint_test.sql',
      'fase5_public_snapshot_fingerprint_test.sql'
    )
    $currentContractTests = @(
      Get-ChildItem -LiteralPath $testsDir -File -Filter '*.sql' |
        Where-Object { $historicalFingerprintTests -notcontains $_.Name } |
        Sort-Object Name
    )
    foreach ($testFile in $currentContractTests) {
      Copy-Item -LiteralPath $testFile.FullName -Destination $labTestsDir -Force
    }

    Write-Step 'Ejecutando contratos pgTAP actuales contra snapshot + migraciones pendientes'
    Invoke-Checked -Command 'supabase' -Arguments @('test', 'db', '--local')

    Write-Step 'Ejecutando db lint sobre public'
    Invoke-Checked -Command 'supabase' -Arguments @(
      'db', 'lint', '--local', '--schema', 'public', '--level', 'error', '--fail-on', 'error'
    )

    Write-Host ''
    Write-Host 'LAB SQL COMPLETO: snapshot remoto + migraciones pendientes + pgTAP + lint = OK.' -ForegroundColor Green
    Write-Host 'El proyecto remoto NO fue modificado.' -ForegroundColor Green
  }
  finally {
    Pop-Location
  }
}
finally {
  Pop-Location

  if ($labStarted -and -not $KeepLab) {
    Push-Location -LiteralPath $labRoot
    try {
      Write-Step 'Eliminando laboratorio temporal'
      & supabase stop --no-backup
      if ($LASTEXITCODE -ne 0) {
        Write-Warning 'No se pudo detener automaticamente el laboratorio. Revisa Docker Desktop.'
      }
    }
    finally {
      Pop-Location
    }
  }

  if (-not $KeepLab -and (Test-Path -LiteralPath $labRoot)) {
    try {
      Remove-Item -LiteralPath $labRoot -Recurse -Force -ErrorAction Stop
    }
    catch {
      Write-Warning "No se pudo borrar completamente el laboratorio temporal: $labRoot"
    }
  }
  elseif ($KeepLab) {
    Write-Host "Laboratorio conservado en: $labRoot" -ForegroundColor Yellow
  }
}
