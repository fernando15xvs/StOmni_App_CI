param(
  [string]$SnapshotPath = 'supabase/.snapshots/fase5/public_schema_prod.sql',
  [string]$ExpectedSha256 = 'A274BEE6A36515C529C379A908A620FFF3728326E7815272D385DBEED1CE3275',
  [switch]$KeepLab
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Invoke-Checked { param([Parameter(Mandatory=$true)][string]$Command,[Parameter(Mandatory=$true)][string[]]$Arguments); Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor DarkCyan; & $Command @Arguments; if ($LASTEXITCODE -ne 0) { throw "El comando fallo con codigo ${LASTEXITCODE}: $Command $($Arguments -join ' ')" } }
function Invoke-PsqlFile { param([Parameter(Mandatory=$true)][string]$ContainerId,[Parameter(Mandatory=$true)][string]$SqlPath,[Parameter(Mandatory=$true)][string]$Label); if (-not (Test-Path -LiteralPath $SqlPath)) { throw "No existe el SQL requerido para ${Label}: $SqlPath" }; Write-Step $Label; Write-Host "Archivo: $SqlPath"; $previousOutputEncoding=$OutputEncoding; try { $OutputEncoding=New-Object System.Text.UTF8Encoding($false); Get-Content -LiteralPath $SqlPath -Raw -Encoding UTF8 | & docker exec -i $ContainerId psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres; $exitCode=$LASTEXITCODE } finally { $OutputEncoding=$previousOutputEncoding }; if ($exitCode -ne 0) { throw "psql fallo con codigo ${exitCode} al ejecutar: $SqlPath" } }

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedSnapshot = if ([System.IO.Path]::IsPathRooted($SnapshotPath)) { $SnapshotPath } else { Join-Path $repoRoot $SnapshotPath }
if (-not (Test-Path -LiteralPath $resolvedSnapshot)) { throw "No existe el snapshot: $resolvedSnapshot" }
$resolvedSnapshot=(Resolve-Path -LiteralPath $resolvedSnapshot).Path
$snapshotInfo=Get-Item -LiteralPath $resolvedSnapshot
if ($snapshotInfo.Length -lt 100000) { throw "Snapshot incompleto: $($snapshotInfo.Length) bytes. Se esperaban mas de 100000 bytes." }
$actualHash=(Get-FileHash -LiteralPath $resolvedSnapshot -Algorithm SHA256).Hash.ToUpperInvariant()
if ($ExpectedSha256 -and $actualHash -ne $ExpectedSha256.ToUpperInvariant()) { throw "SHA-256 inesperado. Esperado: $ExpectedSha256 / Actual: $actualHash" }
if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw 'Supabase CLI no esta disponible en PATH.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker no esta disponible en PATH.' }

Write-Host 'StOmni - Laboratorio local Fase 5' -ForegroundColor Green
Write-Host "Snapshot: $resolvedSnapshot"
Write-Host "Bytes: $($snapshotInfo.Length)"
Write-Host "SHA256: $actualHash"
Write-Host 'Este script NO usa --linked, db push, migration repair ni SQL remoto.' -ForegroundColor Yellow
Invoke-Checked -Command 'supabase' -Arguments @('--version')
Invoke-Checked -Command 'docker' -Arguments @('version','--format','{{.Server.Version}}')
$existingDbContainers=@(& docker ps --filter 'name=supabase_db_' --format '{{.ID}}|{{.Names}}')
if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar los contenedores Docker actuales.' }
if ($existingDbContainers.Count -gt 0) { throw ("Ya existe una base Supabase local ejecutandose. Detenla de forma explicita antes de abrir el laboratorio Fase 5. Detectado: " + ($existingDbContainers -join ', ')) }

$labRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('stomni-fase5-lab-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
$dbContainer=$null; $labStarted=$false
$pendingMigrations=@(
  (Join-Path $repoRoot 'supabase/migrations/20260822052046_debt_payment_idempotency.sql'),
  (Join-Path $repoRoot 'supabase/migrations/20260822052056_warehouse_deactivation_integrity.sql'),
  (Join-Path $repoRoot 'supabase/migrations/20260822052106_advisor_safe_hardening.sql'),
  (Join-Path $repoRoot 'supabase/migrations/20260822052115_expense_mutation_atomicity.sql')
)
$fingerprintSource=Join-Path $repoRoot 'supabase/tests/database/fase5_public_snapshot_fingerprint_test.sql'
$contractSources=@(
  (Join-Path $repoRoot 'supabase/tests/database/debt_payment_v2_contract_test.sql'),
  (Join-Path $repoRoot 'supabase/tests/database/warehouse_deactivation_contract_test.sql'),
  (Join-Path $repoRoot 'supabase/tests/database/business_config_rpc_contract_test.sql'),
  (Join-Path $repoRoot 'supabase/tests/database/expense_mutation_atomicity_contract_test.sql'),
  (Join-Path $repoRoot 'supabase/tests/database/data_api_surface_hardening_contract_test.sql'),
  (Join-Path $repoRoot 'supabase/tests/database/tributary_rpc_legacy_cleanup_contract_test.sql')
)
foreach ($requiredFile in @($pendingMigrations + @($fingerprintSource) + $contractSources)) { if (-not (Test-Path -LiteralPath $requiredFile)) { throw "Falta un archivo requerido del laboratorio: $requiredFile" } }

Push-Location $labRoot
try {
  Write-Step 'Inicializando proyecto Supabase temporal aislado'; Invoke-Checked -Command 'supabase' -Arguments @('init')
  Write-Step 'Iniciando SOLO la base Postgres local del laboratorio'; Invoke-Checked -Command 'supabase' -Arguments @('db','start'); $labStarted=$true
  $dbContainers=@(& docker ps --filter 'name=supabase_db_' --format '{{.ID}}|{{.Names}}')
  if ($LASTEXITCODE -ne 0) { throw 'No se pudo localizar la base Docker del laboratorio.' }
  if ($dbContainers.Count -ne 1) { throw "Se esperaba exactamente 1 contenedor supabase_db_ y se encontraron $($dbContainers.Count)." }
  $dbContainer=($dbContainers[0] -split '\|',2)[0]
  if (-not $dbContainer) { throw 'No se pudo resolver el ID del contenedor Postgres local.' }
  Write-Host "DB local del laboratorio: $dbContainer" -ForegroundColor DarkGray
  Invoke-PsqlFile -ContainerId $dbContainer -SqlPath $resolvedSnapshot -Label 'Restaurando snapshot public exacto de produccion en LOCAL'
  $labTestsDir=Join-Path $labRoot 'supabase/tests/database'; New-Item -ItemType Directory -Path $labTestsDir -Force | Out-Null
  $fingerprintLab=Join-Path $labTestsDir 'fase5_public_snapshot_fingerprint_test.sql'; Copy-Item -LiteralPath $fingerprintSource -Destination $fingerprintLab -Force
  Write-Step 'Validando huella public PRE-Fase 5 con pgTAP'; Invoke-Checked -Command 'supabase' -Arguments @('test','db','--local','supabase/tests/database/fase5_public_snapshot_fingerprint_test.sql')
  foreach ($migration in $pendingMigrations) { Invoke-PsqlFile -ContainerId $dbContainer -SqlPath $migration -Label ("Aplicando SOLO EN LOCAL: " + [System.IO.Path]::GetFileName($migration)) }
  $contractLabPaths=@(); foreach ($contract in $contractSources) { $destination=Join-Path $labTestsDir ([System.IO.Path]::GetFileName($contract)); Copy-Item -LiteralPath $contract -Destination $destination -Force; $contractLabPaths+=('supabase/tests/database/'+[System.IO.Path]::GetFileName($contract)) }
  Write-Step 'Ejecutando contratos POST-Fase 5 con pgTAP'; Invoke-Checked -Command 'supabase' -Arguments (@('test','db','--local')+$contractLabPaths)
  Write-Step 'Ejecutando db lint sobre public'; Invoke-Checked -Command 'supabase' -Arguments @('db','lint','--local','--schema','public','--level','error','--fail-on','error')
  Write-Host ''; Write-Host 'FASE 5 LAB: VALIDACION LOCAL COMPLETADA.' -ForegroundColor Green; Write-Host 'Snapshot de produccion: OK' -ForegroundColor Green; Write-Host '4 migraciones pendientes: OK' -ForegroundColor Green; Write-Host 'Contratos pgTAP: OK' -ForegroundColor Green; Write-Host 'db lint public: OK' -ForegroundColor Green; Write-Host 'Produccion NO fue modificada.' -ForegroundColor Green
}
finally {
  Pop-Location
  if ($labStarted -and -not $KeepLab) { Push-Location $labRoot; try { Write-Step 'Eliminando laboratorio local temporal'; & supabase stop --no-backup; if ($LASTEXITCODE -ne 0) { Write-Warning 'Supabase no pudo detener el laboratorio automaticamente. Revisa Docker Desktop.' } } finally { Pop-Location } }
  if (-not $KeepLab) { try { Remove-Item -LiteralPath $labRoot -Recurse -Force -ErrorAction Stop } catch { Write-Warning "No se pudo borrar completamente el directorio temporal: $labRoot" } } else { Write-Host "Laboratorio conservado en: $labRoot" -ForegroundColor Yellow }
}
