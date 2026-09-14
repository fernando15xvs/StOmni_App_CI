param(
  [string]$TargetVersion = '20260821191000',
  [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor Cyan
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "El comando fallo con codigo ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $repoRoot 'supabase/migrations/20260722180810_remote_schema.sql'
$fingerprintTest = 'supabase/tests/database/fase5_production_fingerprint_test.sql'
$fase5ContractTests = @(
  'supabase/tests/database/debt_payment_v2_contract_test.sql',
  'supabase/tests/database/warehouse_deactivation_contract_test.sql',
  'supabase/tests/database/business_config_rpc_contract_test.sql',
  'supabase/tests/database/expense_mutation_atomicity_contract_test.sql',
  'supabase/tests/database/data_api_surface_hardening_contract_test.sql',
  'supabase/tests/database/tributary_rpc_legacy_cleanup_contract_test.sql'
)

Push-Location $repoRoot
try {
  if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
    throw 'Supabase CLI no esta instalado o no esta disponible en PATH.'
  }
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker no esta instalado o no esta disponible en PATH.'
  }

  Invoke-Checked -Command 'supabase' -Arguments @('--version')
  Invoke-Checked -Command 'docker' -Arguments @('version', '--format', '{{.Server.Version}}')

  if (-not (Test-Path $baselinePath)) {
    throw "P0 bloqueado: no existe el baseline esperado: $baselinePath"
  }

  $baselineSize = (Get-Item $baselinePath).Length
  if ($baselineSize -lt 1024) {
    throw (
      "P0 bloqueado: el baseline historico sigue vacio/incompleto ($baselineSize bytes). " +
      "No lo rellenes con el dump actual ni uses migration repair. Para validar Fase 5 " +
      "contra el snapshot real usa scripts/fase5_snapshot_lab_verify.ps1."
    )
  }

  if (-not $SkipStart) {
    & supabase status *> $null
    if ($LASTEXITCODE -ne 0) {
      Invoke-Checked -Command 'supabase' -Arguments @('start')
    }
  }

  # Seguridad deliberada: este script nunca acepta --linked ni --db-url.
  # Todos los resets destruyen exclusivamente la base LOCAL de Supabase.
  Write-Host ''
  Write-Host 'FASE 5 / ETAPA 1: reconstruyendo el corte equivalente a produccion...' -ForegroundColor Yellow
  Invoke-Checked -Command 'supabase' -Arguments @(
    'db', 'reset', '--local', '--no-seed', '--version', $TargetVersion
  )

  Invoke-Checked -Command 'supabase' -Arguments @(
    'test', 'db', '--local', $fingerprintTest
  )

  Write-Host ''
  Write-Host 'FASE 5 / ETAPA 2: reconstruyendo todas las migraciones de Fase 5...' -ForegroundColor Yellow
  Invoke-Checked -Command 'supabase' -Arguments @(
    'db', 'reset', '--local', '--no-seed'
  )

  Invoke-Checked -Command 'supabase' -Arguments (
    @('test', 'db', '--local') + $fase5ContractTests
  )

  Invoke-Checked -Command 'supabase' -Arguments @(
    'db', 'lint', '--local', '--schema', 'public', '--level', 'error', '--fail-on', 'error'
  )

  Write-Host ''
  Write-Host 'FASE 5: reconstruccion local completa verificada correctamente.' -ForegroundColor Green
  Write-Host "Huella de produccion validada en el corte: $TargetVersion" -ForegroundColor Green
  Write-Host 'Contratos post-migracion Fase 5 verificados.' -ForegroundColor Green
  Write-Host 'No se modifico ningun proyecto remoto.' -ForegroundColor Green
}
finally {
  Pop-Location
}
