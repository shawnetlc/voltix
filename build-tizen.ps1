[CmdletBinding()]
param(
  [ValidateSet('release', 'debug')]
  [Alias('Mode')]
  [string]$BuildMode = 'release',
  [switch]$DebugBuild,
  [string]$SecurityProfile = $env:VOLTIX_TIZEN_SECURITY_PROFILE,
  [string]$DeviceProfile = 'tv',
  [ValidateSet('tv', 'emulator')]
  [string]$Target = $(if ($env:VOLTIX_TIZEN_TARGET) { $env:VOLTIX_TIZEN_TARGET } else { 'tv' }),
  [string]$TizenApiVersion = $env:VOLTIX_TIZEN_API_VERSION,
  [string]$TizenTargetFramework = $env:VOLTIX_TIZEN_TARGET_FRAMEWORK
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($repoRoot.Contains(' ')) {
  try {
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $short = $fso.GetFolder($repoRoot).ShortPath
    if ($short) { $repoRoot = $short }
  } catch {}
}
$appName = "Voltix"
$appId = "org.voltix.tizen"
if ($DebugBuild) { $BuildMode = 'debug' }

$outputDir = Join-Path $repoRoot "build\tizen\tpk"
$manifestPath = Join-Path $repoRoot "tizen\tizen-manifest.xml"
$csprojPath = Join-Path $repoRoot "tizen\Runner.csproj"

function Get-AppVersion {
  $pubspecPath = Join-Path $repoRoot "pubspec.yaml"
  if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at $pubspecPath"
  }

  $versionLine = Get-Content $pubspecPath | Where-Object { $_ -match '^version\s*:\s*' } | Select-Object -First 1
  if (-not $versionLine) {
    throw "Could not find version in pubspec.yaml"
  }

  $fullVersion = ($versionLine -split ':', 2)[1].Trim()
  $version = ($fullVersion -split '\+', 2)[0].Trim()
  if ([string]::IsNullOrWhiteSpace($version)) {
    return "unknown"
  }
  return $version
}

function Get-FrameworkFromApiVersion([string]$apiVer) {
  return "tizen" + ($apiVer -replace '\.', '')
}

function Get-ApiVersionFromFramework([string]$framework) {
  $digits = $framework -replace '^tizen', ''
  if ($digits.Length -ge 2) {
    $prefix = $digits.Substring(0, $digits.Length - 1)
    $last = $digits.Substring($digits.Length - 1)
    return "$prefix.$last"
  }
  return $digits
}

if (-not $TizenApiVersion -and -not $TizenTargetFramework) {
  $TizenApiVersion = "8.0"
  $TizenTargetFramework = Get-FrameworkFromApiVersion $TizenApiVersion
} elseif ($TizenApiVersion -and -not $TizenTargetFramework) {
  $TizenTargetFramework = Get-FrameworkFromApiVersion $TizenApiVersion
} elseif (-not $TizenApiVersion -and $TizenTargetFramework) {
  $TizenApiVersion = Get-ApiVersionFromFramework $TizenTargetFramework
}

function Find-FlutterTizen {
  if ($env:FLUTTER_TIZEN_BIN -and (Test-Path $env:FLUTTER_TIZEN_BIN)) {
    return $env:FLUTTER_TIZEN_BIN
  }

  $bundledCandidate = Get-ChildItem -Path $repoRoot -Directory -Filter "flutter-tizen*" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($bundledCandidate) {
    $batPath = Join-Path $bundledCandidate.FullName "bin\flutter-tizen.bat"
    if (Test-Path $batPath) { return $batPath }
  }

  $cmd = Get-Command flutter-tizen -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmdBat = Get-Command flutter-tizen.bat -ErrorAction SilentlyContinue
  if ($cmdBat) { return $cmdBat.Source }

  $candidates = @(
    "$env:USERPROFILE\flutter-tizen\bin\flutter-tizen.bat",
    "$env:USERPROFILE\Documents\flutter-tizen\bin\flutter-tizen.bat",
    "C:\flutter-tizen\bin\flutter-tizen.bat"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }

  throw "flutter-tizen not found. Clone https://github.com/flutter-tizen/flutter-tizen, add its bin/ to PATH, or set FLUTTER_TIZEN_BIN."
}

$flutterTizen = Find-FlutterTizen
$appVersion = Get-AppVersion

Write-Host "==> Using flutter-tizen: $flutterTizen" -ForegroundColor Cyan
Write-Host "==> Tizen target: $Target (api=$TizenApiVersion, framework=$TizenTargetFramework)" -ForegroundColor Cyan

$manifestBackup = [System.IO.Path]::GetTempFileName()
$csprojBackup = [System.IO.Path]::GetTempFileName()
Copy-Item $manifestPath $manifestBackup -Force
Copy-Item $csprojPath $csprojBackup -Force

function Restore-Files {
  if (Test-Path $manifestBackup) {
    Copy-Item $manifestBackup $manifestPath -Force
    Remove-Item $manifestBackup -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $csprojBackup) {
    Copy-Item $csprojBackup $csprojPath -Force
    Remove-Item $csprojBackup -Force -ErrorAction SilentlyContinue
  }
}

Push-Location $repoRoot
try {
  $csprojContent = Get-Content $csprojPath -Raw
  $csprojContent = $csprojContent -replace '<TargetFramework>[^<]+</TargetFramework>', "<TargetFramework>$TizenTargetFramework</TargetFramework>"
  Set-Content $csprojPath $csprojContent -Encoding UTF8

  $manifestContent = Get-Content $manifestPath -Raw
  $manifestContent = $manifestContent -replace 'api-version="[^"]+"', "api-version=`"$TizenApiVersion`""
  Set-Content $manifestPath $manifestContent -Encoding UTF8

  Write-Host "==> Resolving dependencies (flutter-tizen pub get)"
  & $flutterTizen config --enable-native-assets | Out-Null
  & $flutterTizen pub get
  if ($LASTEXITCODE -ne 0) {
    throw "flutter-tizen pub get failed with exit code $LASTEXITCODE"
  }

  $targetEntrypoint = Join-Path $repoRoot "lib\main.dart"
  $buildArgs = @(
    "build",
    "tpk",
    "--$BuildMode",
    "--device-profile", $DeviceProfile,
    "--dart-define=VOLTIX_TIZEN=true",
    "-t", $targetEntrypoint
  )

  if ($SecurityProfile) {
    $buildArgs += @("--security-profile", $SecurityProfile)
    Write-Host "==> Signing with security profile: $SecurityProfile"
  } else {
    Write-Host "==> Signing with the active Tizen security profile (none specified)"
  }

  Write-Host "==> Building $appName ($appId) .tpk [$BuildMode, profile=$DeviceProfile]"
  & $flutterTizen @buildArgs
  if ($LASTEXITCODE -ne 0) {
    throw "flutter-tizen build tpk failed with exit code $LASTEXITCODE"
  }

  if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
  }

  $tpks = Get-ChildItem -Path $outputDir -Filter "*.tpk" -ErrorAction SilentlyContinue
  if (-not $tpks -or $tpks.Count -eq 0) {
    Write-Warning "No .tpk found under $outputDir; check the build output above."
  } else {
    Write-Host "==> Built .tpk artifact(s):" -ForegroundColor Green
    foreach ($tpk in $tpks) {
      Write-Host "    $($tpk.FullName)"
    }

    $latestTpk = $tpks | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $rootArtifact = Join-Path $repoRoot "${appName}_Tizen_v${appVersion}.tpk"
    Copy-Item $latestTpk.FullName $rootArtifact -Force
    Write-Host "==> Copied root artifact: $rootArtifact" -ForegroundColor Green
  }

  Write-Host "==> Done. Install on a TV/emulator with:" -ForegroundColor Green
  Write-Host "    $flutterTizen install"
  Write-Host "    or: tizen install -n <file>.tpk -t <target>"
}
finally {
  Restore-Files
  Pop-Location
}
