param(
  [string]$ProjectRef = 'rbieglhxufocxvxmyswo',
  [switch]$LinkProject
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-SupabaseCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [string]$LogPath,
    [string]$FailureHint
  )

  # Windows PowerShell 5.1 convierte stderr de procesos nativos en
  # NativeCommandError cuando ErrorActionPreference=Stop. Supabase usa stderr
  # tambien para mensajes informativos (por ejemplo "Initialising login role...").
  # Capturamos la salida con Continue y decidimos por el exit code real.
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & supabase @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  $lines = @($output | ForEach-Object { $_.ToString() })
  if ($LogPath) {
    $lines | Set-Content -Encoding UTF8 $LogPath
  }
  $lines | ForEach-Object { Write-Host $_ }

  if ($exitCode -ne 0) {
    if ($FailureHint) {
      Write-Host "`n$FailureHint" -ForegroundColor Yellow
    }
    throw "Supabase CLI termino con codigo ${exitCode}: supabase $($Arguments -join ' ')"
  }
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
  throw 'No se encontro Supabase CLI en PATH. Instala/activa Supabase CLI antes de ejecutar este script.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$snapshotDir = Join-Path $repoRoot 'supabase/.snapshots/fase5'
New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

Write-Host 'Fase 5 - Snapshot Supabase SOLO LECTURA' -ForegroundColor Green
Write-Host "Proyecto esperado: $ProjectRef"
Write-Host 'Este script NO ejecuta db push, db reset, migration repair ni DDL.' -ForegroundColor Yellow

if ($LinkProject) {
  Write-Step 'Vinculando el repositorio al proyecto indicado'
  Write-Host 'supabase link puede solicitar la contrasena de la base. Solo modifica la configuracion local del CLI; no aplica migraciones.' -ForegroundColor Yellow
  Invoke-SupabaseCommand -Arguments @('link', '--project-ref', $ProjectRef) -LogPath (Join-Path $snapshotDir 'link.txt') -FailureHint 'Si aparece un error de privilegios/403, autentica el CLI con la cuenta propietaria o administradora del proyecto: ejecuta supabase login, luego supabase projects list. No compartas tu access token ni la contrasena de la base.'
}

Write-Step 'Version de Supabase CLI'
Invoke-SupabaseCommand -Arguments @('--version') -LogPath (Join-Path $snapshotDir 'cli_version.txt')

Write-Step 'Comparando historial de migraciones local vs remoto'
Invoke-SupabaseCommand -Arguments @('migration', 'list', '--linked') -LogPath (Join-Path $snapshotDir 'migration_list.txt') -FailureHint 'Si el CLI indica falta de privilegios, ejecuta supabase login con la cuenta que tiene acceso al proyecto y confirma que el proyecto aparece en supabase projects list. No uses migration repair.'

Write-Step 'Exportando esquema public actual de produccion'
$schemaFile = Join-Path $snapshotDir 'public_schema.sql'
$tempSchemaFile = Join-Path $snapshotDir ("public_schema.tmp.{0}.sql" -f ([guid]::NewGuid().ToString('N')))

try {
  # El CLI puede crear/truncar el destino antes de completar el dump. Para no
  # destruir un snapshot valido si Docker/conexion falla, volcamos primero a
  # un temporal y solo reemplazamos el snapshot canonico despues de validarlo.
  Invoke-SupabaseCommand -Arguments @('db', 'dump', '--linked', '--schema', 'public', '-f', $tempSchemaFile) -LogPath (Join-Path $snapshotDir 'db_dump.txt') -FailureHint 'El dump requiere que el proyecto este correctamente vinculado y que Docker Desktop este ejecutandose. No uses db push ni db reset para corregir este paso.'

  if (-not (Test-Path $tempSchemaFile)) {
    throw 'No se genero el archivo temporal del dump de public.'
  }

  $tempInfo = Get-Item $tempSchemaFile
  if ($tempInfo.Length -lt 1000) {
    throw "El dump temporal de public parece incompleto ($($tempInfo.Length) bytes). El snapshot canonico anterior no sera reemplazado."
  }

  $tempHash = Get-FileHash -Algorithm SHA256 $tempSchemaFile
  Move-Item -LiteralPath $tempSchemaFile -Destination $schemaFile -Force
}
finally {
  if (Test-Path $tempSchemaFile) {
    Remove-Item -LiteralPath $tempSchemaFile -Force -ErrorAction SilentlyContinue
  }
}

$schemaInfo = Get-Item $schemaFile
if ($schemaInfo.Length -lt 1000) {
  throw "El snapshot final de public parece incompleto ($($schemaInfo.Length) bytes)."
}

Write-Step 'Calculando SHA-256 del snapshot'
$hash = Get-FileHash -Algorithm SHA256 $schemaFile
if ($hash.Hash -ne $tempHash.Hash) {
  throw 'El hash del snapshot final no coincide con el dump temporal validado.'
}
$hash | Format-List | Out-String | Set-Content -Encoding UTF8 (Join-Path $snapshotDir 'public_schema.sha256.txt')
Write-Host "Tamano: $($schemaInfo.Length) bytes"
Write-Host "SHA256: $($hash.Hash)"

Write-Step 'Buscando referencias legacy en el snapshot (solo diagnostico)'
$legacyPattern = "'vendedor'|'almacenero'|'supervisor'|'administrador'"
Select-String -Path $schemaFile -Pattern $legacyPattern -CaseSensitive:$false |
  ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() } |
  Set-Content -Encoding UTF8 (Join-Path $snapshotDir 'legacy_role_hits.txt')

Write-Step 'Buscando policies publicas permisivas (solo diagnostico textual)'
Select-String -Path $schemaFile -Pattern 'TO public|TO PUBLIC|USING \(true\)|WITH CHECK \(true\)' |
  ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() } |
  Set-Content -Encoding UTF8 (Join-Path $snapshotDir 'public_policy_hits.txt')

Write-Host "`nSnapshot creado en: $snapshotDir" -ForegroundColor Green
Write-Host 'Archivos .snapshots estan ignorados por Git y pueden contener detalles del esquema. No los publiques sin revision.' -ForegroundColor Yellow
Write-Host 'Siguiente paso seguro: revisar public_schema.sql y migration_list.txt. NO ejecutar migration repair ni db push.' -ForegroundColor Yellow
