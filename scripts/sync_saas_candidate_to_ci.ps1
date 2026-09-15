param(
  [string]$CiRepositoryUrl = 'https://github.com/fernando15xvs/StOmni_App_CI.git',
  [string]$Branch = 'feature/saas-multitenant-foundation',
  [switch]$TriggerActions,
  [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# La restauración desde Supabase verifica primero la identidad RAW recuperada por
# `supabase migration fetch` (SHA-256 9bebff...). Al entrar en Git, `.gitattributes`
# fuerza `*.sql text eol=lf`, por lo que el artefacto canónico versionado/archivado
# tiene un SHA-256 distinto aunque el SQL sea el mismo. Este sync valida la identidad
# CANÓNICA DE GIT porque copia exactamente un `git archive` del commit candidato.
$ExpectedCanonicalBootstrapSha256 = 'c6421682c5a64ee026d864483315c32e6e814b595fa91dfde527699236ad31ed'

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Falló: $FilePath $($Arguments -join ' ') (exit $LASTEXITCODE)"
  }
}

$sourceRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceRoot) {
  throw 'Ejecuta este script dentro del repositorio StOmni_App.'
}

Push-Location $sourceRoot
try {
  $currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
  if ($currentBranch -ne $Branch) {
    throw "Rama incorrecta. Esperada '$Branch', actual '$currentBranch'."
  }

  $dirty = (& git status --porcelain)
  if ($dirty) {
    throw "El repositorio fuente debe estar limpio antes de sincronizar CI.`n$($dirty -join "`n")"
  }

  $sourceSha = (& git rev-parse HEAD).Trim()
  if ($sourceSha -notmatch '^[0-9a-f]{40}$') {
    throw 'No se pudo resolver el SHA fuente.'
  }

  # El espejo CI es público. Este gate corre ANTES de cualquier push para evitar
  # publicar accidentalmente archivos/credenciales sensibles y después detectarlos.
  $trackedFiles = @(& git ls-files)
  $sensitiveTracked = @($trackedFiles | Where-Object {
    $_ -match '(^|/)\.env$' -or
    $_ -match '(^|/)\.env\.(local|prod|production)$' -or
    $_ -match '^supabase/\.(temp|branches)/' -or
    $_ -match '\.(pem|p12|pfx|key|jks|keystore)$' -or
    $_ -match '(^|/)(id_rsa|id_ed25519)$'
  })
  if ($sensitiveTracked.Count -gt 0) {
    throw "Se aborta el mirror público: hay rutas sensibles versionadas.`n$($sensitiveTracked -join "`n")"
  }

  if (-not (Test-Path (Join-Path $sourceRoot 'scripts/verify_saas_final_security.mjs'))) {
    throw 'Falta scripts/verify_saas_final_security.mjs; no se publicará el espejo CI.'
  }
  Invoke-Checked node scripts/verify_saas_final_security.mjs --self-test
  Invoke-Checked node scripts/verify_saas_final_security.mjs

  $ownsTemp = [string]::IsNullOrWhiteSpace($WorkDir)
  if ($ownsTemp) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("stomni-ci-sync-" + [Guid]::NewGuid().ToString('N'))
  } else {
    $WorkDir = [IO.Path]::GetFullPath($WorkDir)
    if (Test-Path $WorkDir) {
      throw "WorkDir ya existe: $WorkDir"
    }
  }

  New-Item -ItemType Directory -Path $WorkDir | Out-Null
  $ciDir = Join-Path $WorkDir 'StOmni_App_CI'
  $archivePath = Join-Path $WorkDir 'candidate.tar'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  Write-Host "SOURCE repo   : fernando15xvs/StOmni_App"
  Write-Host "SOURCE branch : $Branch"
  Write-Host "SOURCE SHA    : $sourceSha"
  Write-Host "CI repo       : $CiRepositoryUrl"

  Invoke-Checked git clone --branch $Branch --single-branch $CiRepositoryUrl $ciDir

  $ciOnlyPaths = @(
    '.github/workflows/supabase_include_probe.yml',
    '.github/workflows/supabase_mount_probe.yml',
    '.github/workflows/supabase_pgcrypto_probe.yml',
    '.github/include-probe-trigger',
    '.github/mount-probe-trigger',
    '.github/pgcrypto-probe-trigger'
  )

  $preserved = @{}
  foreach ($relative in $ciOnlyPaths) {
    $full = Join-Path $ciDir $relative
    if (Test-Path $full) {
      $preserved[$relative] = [IO.File]::ReadAllBytes($full)
    }
  }

  Get-ChildItem -LiteralPath $ciDir -Force |
    Where-Object { $_.Name -ne '.git' } |
    Remove-Item -Recurse -Force

  Invoke-Checked git -C $sourceRoot archive --format=tar --output=$archivePath $sourceSha
  Invoke-Checked tar -xf $archivePath -C $ciDir

  foreach ($relative in $preserved.Keys) {
    $full = Join-Path $ciDir $relative
    $parent = Split-Path -Parent $full
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllBytes($full, $preserved[$relative])
  }

  $bootstrap = Join-Path $ciDir 'supabase/migrations/20260822052116_bootstrap_public_schema.sql'
  if (-not (Test-Path $bootstrap)) {
    throw 'La baseline SaaS exacta no existe después del mirror. Se aborta el sync.'
  }

  $bootstrapSha256 = (Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($bootstrapSha256 -ne $ExpectedCanonicalBootstrapSha256) {
    throw "La baseline canónica Git del candidato no coincide con el hash esperado. Esperado=$ExpectedCanonicalBootstrapSha256 Actual=$bootstrapSha256"
  }

  $manifestPath = Join-Path $ciDir 'docs/saas/CI_CANDIDATE_SOURCE.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null

  $manifest = [ordered]@{
    source_repository = 'fernando15xvs/StOmni_App'
    source_branch = $Branch
    source_sha = $sourceSha
    synchronized_at_utc = [DateTime]::UtcNow.ToString('o')
    sync_mode = 'git-archive-mirror'
    bootstrap_path = 'supabase/migrations/20260822052116_bootstrap_public_schema.sql'
    bootstrap_sha256_checkout = $bootstrapSha256
    bootstrap_identity_kind = 'canonical-git-lf'
    actions_trigger_requested = [bool]$TriggerActions
  }
  $manifestJson = ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine
  [IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

  if ($TriggerActions) {
    $triggerPath = Join-Path $ciDir '.github/saas-ci-trigger'
    $triggerText = @(
      "source_sha=$sourceSha"
      "triggered_at_utc=$([DateTime]::UtcNow.ToString('o'))"
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($triggerPath, $triggerText + [Environment]::NewLine, $utf8NoBom)
  }

  Push-Location $ciDir
  try {
    Invoke-Checked -FilePath 'git' -Arguments @('add', '-A')
    $status = (& git status --short)
    if (-not $status) {
      Write-Host 'CI mirror ya estaba idéntico; no hay cambios que publicar.'
      exit 0
    }

    if (-not (& git config user.name)) {
      Invoke-Checked git config user.name 'StOmni CI Sync'
    }
    if (-not (& git config user.email)) {
      Invoke-Checked git config user.email 'stomni-ci-sync@users.noreply.github.com'
    }

    $shortSha = $sourceSha.Substring(0, 12)
    Invoke-Checked git commit -m "ci: sync candidate $shortSha"
    Invoke-Checked git push origin $Branch
    $ciSha = (& git rev-parse HEAD).Trim()

    Write-Host ''
    Write-Host 'CI MIRROR SINCRONIZADO'
    Write-Host "  source_sha: $sourceSha"
    Write-Host "  ci_sha    : $ciSha"
    Write-Host "  actions   : $([bool]$TriggerActions)"
  }
  finally {
    Pop-Location
  }
}
finally {
  Pop-Location
  if ($ownsTemp -and $WorkDir -and (Test-Path $WorkDir)) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
