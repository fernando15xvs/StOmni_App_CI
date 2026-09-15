[CmdletBinding()]
param(
  [ValidateSet('windows', 'linux', 'macos')]
  [string]$DesktopTarget = 'windows',
  [switch]$SkipSupabase,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$workspaceVerifier = Join-Path $PSScriptRoot 'verify_workspace.ps1'
$architectureVerifier = Join-Path $PSScriptRoot 'verify_architecture.mjs'
$envVerifier = Join-Path $PSScriptRoot 'validate_client_env.dart'
$linkedSchemaLab = Join-Path $PSScriptRoot 'verify_linked_schema_lab.ps1'
$baselinePath = Join-Path $repoRoot 'supabase/migrations/20260722180810_remote_schema.sql'
$testsDir = Join-Path $repoRoot 'supabase/tests/database'
$historicalFingerprintTests = @(
  'fase5_production_fingerprint_test.sql',
  'fase5_public_snapshot_fingerprint_test.sql'
)

function Assert-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "No se encontró '$Name' en PATH. Instálalo antes de continuar."
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][scriptblock]$Command
  )
  Write-Host ''
  Write-Host $Label -ForegroundColor Yellow
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "Fallo '$Label' con código de salida $LASTEXITCODE."
  }
}

Assert-Command git
Assert-Command node
Assert-Command dart
Assert-Command flutter

Push-Location -LiteralPath $repoRoot
try {
  Write-Host 'Validación final local del refactor arquitectónico de StOmni.' -ForegroundColor Green
  Write-Host "Destino Desktop: $DesktopTarget" -ForegroundColor Green

  Invoke-Checked 'Comprobando whitespace y conflictos de patch' {
    git diff --check
  }

  Invoke-Checked 'Ejecutando guard arquitectónico y de versiones Supabase' {
    node $architectureVerifier
  }

  Invoke-Checked 'Validando que el cliente no dependa de secretos/.env inseguros' {
    dart run $envVerifier
  }

  if (-not $SkipSupabase) {
    Assert-Command supabase
    Assert-Command docker

    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
      throw "Falta el baseline histórico esperado: $baselinePath"
    }

    $baselineSize = (Get-Item -LiteralPath $baselinePath).Length
    if ($baselineSize -lt 1024) {
      Write-Host ''
      Write-Host (
        "El baseline histórico está vacío/incompleto ($baselineSize bytes). " +
        'No se ejecutará supabase db reset, porque las migraciones antiguas presuponen el esquema remoto existente.'
      ) -ForegroundColor DarkYellow
      Write-Host (
        'Se usará un laboratorio temporal: snapshot remoto SOLO LECTURA + migraciones posteriores al último timestamp remoto.'
      ) -ForegroundColor DarkYellow

      if (-not (Test-Path -LiteralPath $linkedSchemaLab -PathType Leaf)) {
        throw "Falta el laboratorio SQL esperado: $linkedSchemaLab"
      }
      & $linkedSchemaLab
    }
    else {
      Invoke-Checked 'Iniciando Supabase local' {
        supabase start
      }

      Invoke-Checked 'Recreando la base local desde todas las migraciones' {
        supabase db reset --local
      }

      $currentContractTests = @(
        Get-ChildItem -LiteralPath $testsDir -File -Filter '*.sql' |
          Where-Object { $historicalFingerprintTests -notcontains $_.Name } |
          Sort-Object Name |
          ForEach-Object { $_.FullName }
      )
      if ($currentContractTests.Count -eq 0) {
        throw 'No se encontraron contratos pgTAP actuales para ejecutar.'
      }

      Write-Host (
        "Contratos pgTAP actuales: $($currentContractTests.Count). " +
        'Se excluyen 2 fingerprints históricos PRE-Fase 5 que no pertenecen al esquema SaaS final.'
      ) -ForegroundColor DarkYellow

      Invoke-Checked 'Ejecutando contratos pgTAP actuales de la base local' {
        supabase test db --local @currentContractTests
      }
    }
  }
  else {
    Write-Host ''
    Write-Host 'Supabase local omitido por -SkipSupabase.' -ForegroundColor DarkYellow
  }

  Write-Host ''
  Write-Host 'Ejecutando validación Flutter del workspace...' -ForegroundColor Yellow
  if ($SkipBuild) {
    & $workspaceVerifier -DesktopTarget $DesktopTarget -SkipBuild
  }
  else {
    & $workspaceVerifier -DesktopTarget $DesktopTarget
  }

  Write-Host ''
  Write-Host 'VALIDACIÓN LOCAL COMPLETA: todos los gates ejecutados terminaron correctamente.' -ForegroundColor Green
  if ($SkipSupabase -or $SkipBuild) {
    Write-Host 'Advertencia: se usaron switches de omisión; ejecuta luego sin omisiones antes del merge.' -ForegroundColor DarkYellow
  }
}
finally {
  Pop-Location
}
