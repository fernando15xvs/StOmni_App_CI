[CmdletBinding()]
param(
  [string]$ExpectedProjectRef = 'iqooedpkihmzkmynsisl',
  [string]$TargetVersion = '20260822052116',
  [string]$TargetName = 'bootstrap_public_schema',
  [long]$ExpectedBytes = 523836,
  [string]$ExpectedSha256 = '9bebff236152d0a6f22a2be8e9548e60fadc737ecb16323b30106547cc83eeb4'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$migrationsDir = Join-Path $repoRoot 'supabase/migrations'
$relativeBaseline = "supabase/migrations/${TargetVersion}_${TargetName}.sql"
$baselinePath = Join-Path $repoRoot ($relativeBaseline -replace '/', [IO.Path]::DirectorySeparatorChar)
$projectRefPath = Join-Path $repoRoot 'supabase/.temp/project-ref'
$expectedHash = $ExpectedSha256.ToLowerInvariant()

function Assert-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "No se encontro '$Name' en PATH."
  }
}

function Invoke-CheckedNative {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor DarkCyan
  $previous = $ErrorActionPreference
  try {
    # Windows PowerShell 5.1 puede promover stderr informativo de procesos
    # nativos a NativeCommandError cuando ErrorActionPreference=Stop.
    $ErrorActionPreference = 'Continue'
    & $Command @Arguments
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previous
  }

  if ($exitCode -ne 0) {
    throw "El comando fallo con codigo ${exitCode}: $Command $($Arguments -join ' ')"
  }
}

function Get-FileIdentity {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "No existe el archivo esperado: $Path"
  }
  $info = Get-Item -LiteralPath $Path
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  return [pscustomobject]@{
    Bytes = [long]$info.Length
    Sha256 = $hash
  }
}

function Assert-ExpectedIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $identity = Get-FileIdentity -Path $Path
  Write-Host "${Label}: $($identity.Bytes) bytes / SHA256 $($identity.Sha256)" -ForegroundColor Cyan
  if ($identity.Bytes -ne $ExpectedBytes) {
    throw "${Label}: bytes inesperados. Esperado=$ExpectedBytes / Actual=$($identity.Bytes)"
  }
  if ($identity.Sha256 -ne $expectedHash) {
    throw "${Label}: SHA-256 inesperado. Esperado=$expectedHash / Actual=$($identity.Sha256)"
  }
}

Assert-Command git
Assert-Command supabase

Push-Location -LiteralPath $repoRoot
try {
  Write-Host 'StOmni - restauracion exacta del bootstrap SaaS' -ForegroundColor Green
  Write-Host 'Operacion remota permitida: SOLO lectura del ledger mediante migration fetch.' -ForegroundColor Yellow
  Write-Host 'Este script NO ejecuta db push, migration repair, db reset --linked ni DDL remoto.' -ForegroundColor Yellow

  $branch = (& git branch --show-current).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo resolver la rama Git actual.'
  }
  if ($branch -ne 'feature/saas-multitenant-foundation') {
    throw "Rama incorrecta: '$branch'. Se exige feature/saas-multitenant-foundation."
  }

  $dirtyBefore = @(& git status --porcelain=v1 --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo comprobar git status.'
  }
  if ($dirtyBefore.Count -gt 0) {
    throw ('El arbol Git debe estar limpio antes de restaurar la baseline. Detectado: ' + ($dirtyBefore -join ' | '))
  }

  if (-not (Test-Path -LiteralPath $projectRefPath -PathType Leaf)) {
    throw (
      "No existe $projectRefPath. Vincula localmente el proyecto esperado con: " +
      "supabase link --project-ref $ExpectedProjectRef"
    )
  }
  $linkedRef = (Get-Content -LiteralPath $projectRefPath -Raw -Encoding UTF8).Trim()
  if ($linkedRef -ne $ExpectedProjectRef) {
    throw "Proyecto Supabase vinculado incorrecto. Esperado=$ExpectedProjectRef / Actual=$linkedRef"
  }

  if (-not (Test-Path -LiteralPath $migrationsDir -PathType Container)) {
    throw "No existe el directorio de migraciones: $migrationsDir"
  }
  if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
    throw "No existe el guard de baseline esperado: $baselinePath"
  }

  Invoke-CheckedNative -Command 'supabase' -Arguments @('--version')

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('stomni-bootstrap-fetch-' + [guid]::NewGuid().ToString('N'))
  $originalMigrations = Join-Path $tempRoot 'migrations-original'
  $verifiedCopy = Join-Path $tempRoot ("${TargetVersion}_${TargetName}.verified.sql")
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $migrationsRelocated = $false
  $verified = $false

  try {
    Write-Host ''
    Write-Host '==> Aislando temporalmente las migraciones locales' -ForegroundColor Cyan
    Move-Item -LiteralPath $migrationsDir -Destination $originalMigrations
    $migrationsRelocated = $true
    New-Item -ItemType Directory -Path $migrationsDir -Force | Out-Null

    Write-Host ''
    Write-Host '==> Recuperando el ledger remoto en modo SOLO LECTURA' -ForegroundColor Cyan
    Invoke-CheckedNative -Command 'supabase' -Arguments @('migration', 'fetch', '--linked')

    $expectedFetchedPath = Join-Path $migrationsDir ("${TargetVersion}_${TargetName}.sql")
    if (-not (Test-Path -LiteralPath $expectedFetchedPath -PathType Leaf)) {
      $sameVersion = @(
        Get-ChildItem -LiteralPath $migrationsDir -File -Filter "${TargetVersion}_*.sql" -ErrorAction SilentlyContinue
      )
      $found = if ($sameVersion.Count -gt 0) { $sameVersion.Name -join ', ' } else { '<ninguno>' }
      throw "migration fetch no produjo ${TargetVersion}_${TargetName}.sql. Version $TargetVersion encontrada: $found"
    }

    Assert-ExpectedIdentity -Path $expectedFetchedPath -Label 'Migracion recuperada'
    Copy-Item -LiteralPath $expectedFetchedPath -Destination $verifiedCopy -Force
    Assert-ExpectedIdentity -Path $verifiedCopy -Label 'Copia temporal verificada'
    $verified = $true
  }
  finally {
    Write-Host ''
    Write-Host '==> Restaurando exactamente el directorio de migraciones original' -ForegroundColor Cyan
    if ($migrationsRelocated) {
      if (Test-Path -LiteralPath $migrationsDir) {
        Remove-Item -LiteralPath $migrationsDir -Recurse -Force
      }
      if (-not (Test-Path -LiteralPath $originalMigrations -PathType Container)) {
        throw "No se puede restaurar el directorio original; falta: $originalMigrations"
      }
      Move-Item -LiteralPath $originalMigrations -Destination $migrationsDir
      $migrationsRelocated = $false
    }
  }

  if (-not $verified) {
    throw 'La migracion remota no supero la verificacion; la baseline local no sera reemplazada.'
  }

  Write-Host ''
  Write-Host '==> Sustituyendo el guard por la baseline exacta ya verificada' -ForegroundColor Cyan
  $atomicTemp = "${baselinePath}.verified-$([guid]::NewGuid().ToString('N')).tmp"
  try {
    Copy-Item -LiteralPath $verifiedCopy -Destination $atomicTemp -Force
    Assert-ExpectedIdentity -Path $atomicTemp -Label 'Baseline previa al reemplazo atomico'
    Move-Item -LiteralPath $atomicTemp -Destination $baselinePath -Force
  }
  finally {
    if (Test-Path -LiteralPath $atomicTemp) {
      Remove-Item -LiteralPath $atomicTemp -Force
    }
  }

  Assert-ExpectedIdentity -Path $baselinePath -Label 'Baseline materializada'

  $statusAfter = @(& git status --porcelain=v1 --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo comprobar el estado Git posterior.'
  }
  if ($statusAfter.Count -ne 1 -or $statusAfter[0] -notmatch ([regex]::Escape($relativeBaseline) + '$')) {
    throw ('Se detectaron cambios Git inesperados despues de la restauracion: ' + ($statusAfter -join ' | '))
  }

  Write-Host ''
  Write-Host 'BOOTSTRAP SAAS RESTAURADO Y VERIFICADO.' -ForegroundColor Green
  Write-Host "Archivo: $relativeBaseline" -ForegroundColor Green
  Write-Host "Bytes: $ExpectedBytes" -ForegroundColor Green
  Write-Host "SHA256: $expectedHash" -ForegroundColor Green
  Write-Host 'Proyecto remoto: SOLO LEIDO; no se aplicaron ni repararon migraciones.' -ForegroundColor Green
  Write-Host ''
  & git status --short
  & git diff --stat -- $relativeBaseline
}
finally {
  Pop-Location
}
