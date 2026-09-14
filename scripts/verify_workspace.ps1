[CmdletBinding()]
param(
  [ValidateSet('windows', 'linux', 'macos')]
  [string]$DesktopTarget = 'windows',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Directory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "No existe ${Description}: $Path"
  }
}

function Assert-File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "No existe ${Description}: $Path"
  }
}

function Invoke-FlutterCheck {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  Assert-Directory -Path $WorkingDirectory -Description "el directorio de trabajo para $Label"

  Write-Host ''
  Write-Host $Label -ForegroundColor Yellow
  Write-Host "> flutter $($Arguments -join ' ')" -ForegroundColor Cyan

  Push-Location -LiteralPath $WorkingDirectory
  try {
    & flutter @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "Fallo $Label con codigo de salida $LASTEXITCODE."
    }
  }
  finally {
    Pop-Location
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreLogic = Join-Path $repoRoot 'packages/core_logic'
$mobileApp = Join-Path $repoRoot 'packages/mobile_app'
$desktopApp = Join-Path $repoRoot 'packages/desktop_app'
$mobileArchitectureTests = Join-Path $mobileApp 'test/architecture'
$mobileDependencyTest = Join-Path $mobileApp 'test/core_dependency_test.dart'
$desktopSmokeTest = Join-Path $desktopApp 'test/widget_test.dart'
$desktopPlatformDirectory = Join-Path $desktopApp $DesktopTarget

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw 'Flutter no esta instalado o no esta disponible en PATH.'
}

Assert-File -Path (Join-Path $repoRoot 'pubspec.yaml') -Description 'el pubspec del workspace'
Assert-Directory -Path $coreLogic -Description 'el paquete core_logic'
Assert-Directory -Path $mobileApp -Description 'el paquete mobile_app'
Assert-Directory -Path $desktopApp -Description 'el paquete desktop_app'
Assert-File -Path $mobileDependencyTest -Description 'la prueba de dependencias de mobile_app'
Assert-Directory -Path $mobileArchitectureTests -Description 'las pruebas arquitectonicas de mobile_app'
Assert-File -Path $desktopSmokeTest -Description 'la prueba smoke de desktop_app'

if (-not $SkipBuild) {
  Assert-Directory -Path $desktopPlatformDirectory -Description "la plataforma desktop '$DesktopTarget'"
}

Write-Host 'Verificando el workspace Flutter de forma secuencial.' -ForegroundColor Green
Write-Host "Destino desktop: $DesktopTarget" -ForegroundColor Green
if ($SkipBuild) {
  Write-Host 'El build desktop se omitira por solicitud.' -ForegroundColor DarkYellow
}

# En un pub workspace la resolucion se ejecuta una sola vez desde la raiz.
Invoke-FlutterCheck -Label 'Resolviendo dependencias del workspace' -WorkingDirectory $repoRoot -Arguments @('pub', 'get')

Invoke-FlutterCheck -Label 'Analizando core_logic' -WorkingDirectory $coreLogic -Arguments @('analyze', '--no-pub', '--no-fatal-infos')
Invoke-FlutterCheck -Label 'Ejecutando pruebas de core_logic' -WorkingDirectory $coreLogic -Arguments @('test', '--no-pub')

Invoke-FlutterCheck -Label 'Analizando mobile_app' -WorkingDirectory $mobileApp -Arguments @('analyze', '--no-pub', '--no-fatal-infos')
Invoke-FlutterCheck -Label 'Ejecutando pruebas arquitectonicas de mobile_app' -WorkingDirectory $mobileApp -Arguments @(
  'test',
  '--no-pub',
  'test/core_dependency_test.dart',
  'test/architecture'
)

Invoke-FlutterCheck -Label 'Analizando desktop_app' -WorkingDirectory $desktopApp -Arguments @('analyze', '--no-pub', '--no-fatal-infos')
Invoke-FlutterCheck -Label 'Ejecutando prueba smoke de desktop_app' -WorkingDirectory $desktopApp -Arguments @('test', '--no-pub', 'test/widget_test.dart')

if (-not $SkipBuild) {
  Invoke-FlutterCheck -Label "Compilando desktop_app para $DesktopTarget" -WorkingDirectory $desktopApp -Arguments @(
    'build',
    $DesktopTarget,
    '--debug',
    '--no-pub'
  )
}

Write-Host ''
Write-Host 'Workspace Flutter verificado correctamente.' -ForegroundColor Green
