[CmdletBinding()]
param(
  # Target architecture. 'x64' keeps the original behavior byte-identical;
  # 'arm64' builds the native ARM64 installer on a windows-11-arm runner.
  [ValidateSet('x64', 'arm64')]
  [string]$Architecture = 'x64',

  [switch] $NoBump,
  [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$vcpkgTriplet = "$Architecture-windows"

# -- Versions for this build ------------------------------------------------
# Rewritten in place by Step-BuildNumbers below, and by deploy-app.ps1. Still
# asserted against pubspec.yaml before building, so a hand-edit that desyncs
# them fails loudly rather than stamping one version while checking another.
$sharedVersionName = "2.0.62"
$mobileVersionCode = "40000420"
$tvVersionCode     = "40000421"

function Read-Utf8([string] $Path) { Get-Content -LiteralPath $Path -Raw }

# UTF-8 without BOM: a BOM in pubspec.yaml breaks the Gradle parser that reads
# `version:` straight out of it.
function Write-Utf8([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Advances versionName patch and build numbers, and writes them everywhere they are held.
function Step-BuildNumbers {
    $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
    $pubspec = Read-Utf8 $pubspecPath

    if ($pubspec -notmatch '(?m)^version:[ \t]*([0-9][^+\s]*)\+([0-9]+)[ \t]*\r?$') {
        throw "pubspec.yaml 'version:' is not in x.y.z+build form - cannot bump."
    }
    $currentName   = $Matches[1]
    $currentMobile = [int] $Matches[2]

    if ($pubspec -notmatch '(?m)^[ \t]*android_tv_build_number:[ \t]*([0-9]+)[ \t]*\r?$') {
        throw "pubspec.yaml has no 'android_tv_build_number:' - cannot bump."
    }
    $currentTv = [int] $Matches[1]

    # Increment patch version
    $nameParts = $currentName -split '\.'
    if ($nameParts.Count -ge 3) {
        $major = [int]$nameParts[0]
        $minor = [int]$nameParts[1]
        $patch = [int]$nameParts[2] + 1
        $newName = "$major.$minor.$patch"
    } else {
        $newName = $currentName
    }

    # Base the step on whichever is highest. If the two ever drift apart, this
    # moves both past the high-water mark instead of re-issuing a consumed code.
    $highest      = [Math]::Max($currentMobile, $currentTv)
    $newMobile    = $highest + 1
    $newTv        = $highest + 2

    if ($WhatIf) {
        Write-Host "WHATIF - would bump version and codes:" -ForegroundColor Yellow
        Write-Host "  versionName $currentName -> $newName"
        Write-Host "  mobile      $currentMobile -> $newMobile"
        Write-Host "  TV          $currentTv -> $newTv"
        return $null
    }

    $updated = $pubspec `
        -replace '(?m)^version:[ \t]*[0-9][^+\s]*\+[0-9]+[ \t]*(?=\r?$)', "version: $newName+$newMobile" `
        -replace '(?m)^([ \t]*)android_tv_build_number:[ \t]*[0-9]+[ \t]*(?=\r?$)', "`${1}android_tv_build_number: $newTv"
    Write-Utf8 $pubspecPath $updated
    Write-Host "Bumped version: $currentName -> $newName, mobile $currentMobile -> $newMobile, TV $currentTv -> $newTv" -ForegroundColor Cyan

    # Keep the sibling scripts' pins in step, or their own assertions fail the
    # next time they run. Same set deploy-app.ps1 maintains.
    foreach ($scriptName in @('build_aab.ps1', 'build_apk.ps1', 'build_custom.ps1', 'build-windows.ps1')) {
        $scriptPath = Join-Path $repoRoot $scriptName
        if (-not (Test-Path $scriptPath)) { continue }
        $text = Read-Utf8 $scriptPath
        $text = $text `
            -replace '(?m)^\$sharedVersionName[ \t]*=[ \t]*"[^"]*"', "`$sharedVersionName = `"$newName`"" `
            -replace '(?m)^\$mobileVersionCode[ \t]*=[ \t]*"[^"]*"', "`$mobileVersionCode = `"$newMobile`"" `
            -replace '(?m)^\$tvVersionCode([ \t]*)=[ \t]*"[^"]*"', "`$tvVersionCode`${1}= `"$newTv`""
        Write-Utf8 $scriptPath $text
    }
    Write-Host "Pins updated in build_aab.ps1, build_apk.ps1, build_custom.ps1, build-windows.ps1" -ForegroundColor DarkGray

    return @{ Name = $newName; Mobile = "$newMobile"; Tv = "$newTv" }
}

function Assert-VersionsMatchPubspec {
    $pubspec = Get-Content "$repoRoot\pubspec.yaml" -Raw
    $checks = @(
        @{ Label = 'shared version + mobile code'; Pattern = "(?m)^version:\s*$([regex]::Escape($sharedVersionName))\+$mobileVersionCode\s*$" },
        @{ Label = 'TV build number';              Pattern = "(?m)^\s*android_tv_build_number:\s*$tvVersionCode\s*$" }
    )
    foreach ($check in $checks) {
        if ($pubspec -notmatch $check.Pattern) {
            throw "$($check.Label) in build-windows.ps1 does not match pubspec.yaml - update both before building."
        }
    }

    if ($pubspec -match "(?m)^\s*android_tv_version:") {
        throw "pubspec.yaml still declares android_tv_version - TV and mobile must share one versionName. Remove that key."
    }

    if ([int]$tvVersionCode -eq [int]$mobileVersionCode) {
        throw "TV and mobile versionCodes must differ - they share one Play listing."
    }

    Write-Host "Versions OK - $sharedVersionName (mobile code $mobileVersionCode, TV code $tvVersionCode)" -ForegroundColor Green
}

function Get-IsccPath {
  $candidates = @(
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }

  $regPaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
  )

  foreach ($regPath in $regPaths) {
    if (Test-Path $regPath) {
      $appPath = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue)."Inno Setup: App Path"
      if ($appPath) {
        $iscc = Join-Path $appPath "ISCC.exe"
        if (Test-Path $iscc) { return $iscc }
      }
    }
  }

  throw "ISCC.exe not found. Install Inno Setup 6 first."
}

function Get-FlutterCommand {
  $candidate = "C:\dev\flutter\bin\flutter.bat"
  if (Test-Path $candidate) { return $candidate }

  $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($flutterCmd) { return $flutterCmd.Source }

  throw "Flutter not found. Install Flutter or add it to PATH."
}

function Get-NormalizedVersion {
  param([string]$RawVersion)

  if ([string]::IsNullOrWhiteSpace($RawVersion)) {
    throw "Version string is empty."
  }

  $mainPart = ($RawVersion -split '-', 2)[0].Trim()
  $segments = $mainPart -split '\.'
  if ($segments.Count -lt 3) {
    $segments = @($segments + @('0', '0', '0'))[0..2]
  }

  return [Version]::Parse(($segments -join '.'))
}

function Assert-ToolchainVersions {
  param([string]$FlutterExe)

  $minFlutter = [Version]::Parse('3.41.0')
  $minDart = [Version]::Parse('3.11.0')

  $rawOutput = (& $FlutterExe --version --machine | Out-String)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawOutput)) {
    throw "Failed to query Flutter version. Run 'flutter --version' manually and verify your SDK installation."
  }

  # Flutter can emit setup chatter (e.g. "Running pub upgrade...") before JSON.
  # Extract the JSON object from mixed output to avoid ConvertFrom-Json failures.
  $jsonMatch = [regex]::Match($rawOutput, '\{[\s\S]*\}')
  if (-not $jsonMatch.Success) {
    throw "Failed to parse Flutter --version --machine output as JSON. Raw output: $rawOutput"
  }

  $versionInfo = $jsonMatch.Value | ConvertFrom-Json
  $flutterVersion = Get-NormalizedVersion $versionInfo.frameworkVersion
  $dartVersion = Get-NormalizedVersion $versionInfo.dartSdkVersion

  if ($flutterVersion -lt $minFlutter) {
    throw "Flutter SDK $($versionInfo.frameworkVersion) is too old. Required: 3.41.0+ (README requirement)."
  }

  if ($dartVersion -lt $minDart) {
    throw "Dart SDK $($versionInfo.dartSdkVersion) is too old. Required: 3.11.0+ (README requirement)."
  }
}

# Both vcpkg and `flutter build windows` need the MSVC C++ toolchain. Without
# this check the first failure comes from deep inside vcpkg as
# "Unable to find a valid Visual Studio instance", which reads like vcpkg is
# broken rather than like a missing Visual Studio workload.
#
# Note what that vcpkg error actually means: it lists the paths it probed for
# vcvarsall.bat. If a Visual Studio directory appears in that list but the build
# still fails, Visual Studio IS installed - it just has no C++ workload.
function Assert-VisualStudioCppWorkload {
  param([Parameter(Mandatory)][string] $Architecture)

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) {
    throw @"
Visual Studio not found (no vswhere.exe at $vswhere).

Building Voltix for Windows needs the MSVC C++ toolchain. Install either:
  * Visual Studio 2022 with the 'Desktop development with C++' workload, or
  * Visual Studio 2022 Build Tools (no IDE):
      winget install Microsoft.VisualStudio.2022.BuildTools
    then in the Visual Studio Installer, add 'Desktop development with C++'.
"@
  }

  # Each of these fails deep in the build when absent, with an error that never
  # names the component:
  #   VC.Tools  -> vcpkg: "Unable to find a valid Visual Studio instance"
  #   VC.ATL    -> C1083: Cannot open include file: 'atlbase.h' / 'atlstr.h'
  #
  # ATL is NOT part of the 'Desktop development with C++' workload and has to be
  # ticked separately. flutter_secure_storage_windows and
  # flutter_local_notifications_windows both include ATL headers.
  $required = if ($Architecture -eq 'arm64') {
    @(
      @{ Id = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'; Name = 'MSVC ARM64 build tools' },
      @{ Id = 'Microsoft.VisualStudio.Component.VC.ATL.ARM64';   Name = 'C++ ATL for ARM64' }
    )
  } else {
    @(
      @{ Id = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'; Name = 'MSVC x64/x86 build tools' },
      @{ Id = 'Microsoft.VisualStudio.Component.VC.ATL';           Name = 'C++ ATL for latest build tools' }
    )
  }

  # -prerelease so Preview and Insiders installs are considered too.
  $anyVs = & $vswhere -latest -prerelease -products * -property installationPath 2>$null |
    Select-Object -First 1

  $missing = @()
  $installPath = $null
  foreach ($component in $required) {
    $found = & $vswhere -latest -prerelease -products * `
      -requires $component.Id -property installationPath 2>$null | Select-Object -First 1
    if ($found) {
      if (-not $installPath) { $installPath = $found }
    } else {
      $missing += $component
    }
  }

  if ($missing.Count -gt 0) {
    $lines = ($missing | ForEach-Object { "  * $($_.Name)`n      $($_.Id)" }) -join "`n"

    if ($anyVs) {
      $addArgs = ($missing | ForEach-Object { "--add $($_.Id)" }) -join ' '
      throw @"
Visual Studio is installed at:
  $anyVs
...but these required C++ components are missing:

$lines

Fix via the Visual Studio Installer: choose Modify on that instance, open the
'Individual components' tab, and tick the components above.

Or from a terminal:
  & \"\${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe\" modify ``
      --installPath \"$anyVs\" $addArgs --quiet --norestart

Then open a NEW terminal and run 'flutter clean' before rebuilding.
"@
    }

    throw @"
No Visual Studio instance with C++ tooling was found.

Install Visual Studio 2022 Build Tools with the C++ workload and ATL:
  winget install Microsoft.VisualStudio.2022.BuildTools --override ``
    \"--quiet --add Microsoft.VisualStudio.Workload.VCTools ``
      --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended\"
"@
  }

  $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvarsall.bat'
  if (-not (Test-Path $vcvars)) {
    throw @"
Visual Studio at $installPath reports the C++ component but vcvarsall.bat is
missing at:
  $vcvars

The installation is incomplete. Repair it from the Visual Studio Installer.
"@
  }

  Write-Host "Visual Studio C++ toolchain: $installPath"
}

# flutter_inappwebview_windows fetches its native dependencies (WIL, WebView2,
# nlohmann.json) through NuGet at build time. Without nuget.exe on PATH the
# plugin's CMake step resolves the tool to the literal string NUGET-NOTFOUND,
# then MSBuild tries to execute it and fails with exit code 9009 - a wall of
# MSB3073 lines that never names NuGet as the missing piece.
#
# The plugin does try to self-download nuget.exe first; this check exists because
# that download is silent when it fails.
function Assert-NugetAvailable {
  $nuget = Get-Command nuget -ErrorAction SilentlyContinue
  if ($nuget) {
    Write-Host "NuGet: $($nuget.Source)"
    return
  }

  throw @"
nuget.exe not found on PATH.

The flutter_inappwebview_windows plugin needs it to download its native
dependencies. Install it with:

  winget install Microsoft.NuGet

or download nuget.exe from https://dist.nuget.org/win-x86-commandline/latest/nuget.exe
and place it in a folder that is on PATH.

Then OPEN A NEW TERMINAL so PATH is refreshed, and run:

  flutter clean

That second step is not optional. CMake caches the failed lookup as
NUGET-NOTFOUND, so a rebuild in the same tree keeps failing even once NuGet is
installed correctly.
"@
}

function Get-VcpkgCommand {
  $candidates = @(
    (Join-Path $repoRoot "vcpkg\vcpkg.exe"),
    "C:\vcpkg\vcpkg.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }

  $vcpkgCmd = Get-Command vcpkg -ErrorAction SilentlyContinue
  if ($vcpkgCmd) { return $vcpkgCmd.Source }

  return $null
}

function Initialize-LibarchiveForWindows {
  param(
    [string]$Triplet = 'x64-windows'
  )

  if (-not [Environment]::OSVersion.Platform.ToString().Contains('Win')) {
    return
  }

  $vcpkgExe = Get-VcpkgCommand
  if (-not $vcpkgExe) {
    $bootstrapRoot = Join-Path $repoRoot "vcpkg"
    $bootstrapScript = Join-Path $bootstrapRoot "bootstrap-vcpkg.bat"

    Write-Host "vcpkg not found. Bootstrapping local copy at $bootstrapRoot..."

    if (-not (Test-Path $bootstrapRoot)) {
      $gitCmd = Get-Command git -ErrorAction SilentlyContinue
      if (-not $gitCmd) {
        throw "git not found. Install Git or install vcpkg manually, then run: vcpkg install libarchive:$Triplet"
      }

      & $gitCmd.Source clone https://github.com/microsoft/vcpkg $bootstrapRoot
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone vcpkg repository."
      }
    }

    if (-not (Test-Path $bootstrapScript)) {
      throw "vcpkg bootstrap script not found at $bootstrapScript"
    }

    & $bootstrapScript
    if ($LASTEXITCODE -ne 0) {
      throw "vcpkg bootstrap failed with exit code $LASTEXITCODE"
    }

    $vcpkgExe = Join-Path $bootstrapRoot "vcpkg.exe"
    if (-not (Test-Path $vcpkgExe)) {
      throw "vcpkg executable not found after bootstrap: $vcpkgExe"
    }
  }

  $vcpkgRoot = Split-Path -Parent $vcpkgExe
  $libarchiveHeader = Join-Path $vcpkgRoot "installed\$Triplet\include\archive.h"
  $libarchiveLib = Join-Path $vcpkgRoot "installed\$Triplet\lib\archive.lib"

  if (-not (Test-Path $libarchiveHeader) -or -not (Test-Path $libarchiveLib)) {
    Write-Host "Installing libarchive:$Triplet via vcpkg..."
    & $vcpkgExe install "libarchive:$Triplet"
    if ($LASTEXITCODE -ne 0) {
      throw "vcpkg install libarchive:$Triplet failed with exit code $LASTEXITCODE"
    }
  }

  $env:VCPKG_ROOT = $vcpkgRoot
}

function Copy-VcpkgRuntimeDlls {
  param(
    [string]$VcpkgRoot,
    [string]$ReleaseDir,
    [string]$Triplet = 'x64-windows'
  )

  if ([string]::IsNullOrWhiteSpace($VcpkgRoot) -or -not (Test-Path $VcpkgRoot)) {
    return
  }

  $binDir = Join-Path $VcpkgRoot "installed\$Triplet\bin"
  if (-not (Test-Path $binDir)) {
    return
  }

  $dlls = Get-ChildItem -Path $binDir -Filter *.dll -File -ErrorAction SilentlyContinue
  if (-not $dlls) {
    return
  }

  foreach ($dll in $dlls) {
    Copy-Item -Path $dll.FullName -Destination (Join-Path $ReleaseDir $dll.Name) -Force
  }
}

function Get-AppVersion {
  $pubspecPath = Join-Path $repoRoot "pubspec.yaml"
  if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at $pubspecPath"
  }

  $versionLine = Select-String -Path $pubspecPath -Pattern '^version\s*:\s*' | Select-Object -First 1 -ExpandProperty Line
  if (-not $versionLine) {
    throw "Could not find version in pubspec.yaml"
  }

  $fullVersion = ($versionLine -split ':', 2)[1].Trim()
  $appVersion = ($fullVersion -split '\+', 2)[0].Trim()
  if ([string]::IsNullOrWhiteSpace($appVersion)) {
    throw "Invalid version value in pubspec.yaml: $fullVersion"
  }

  return $appVersion
}

function Invoke-CheckedCommand {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

function New-InnoScript {
  param(
    [string]$AppVersion,
    [string]$InstallerBaseName,
    [string]$OutputDir,
    [string]$IconPath,
    [string]$ReleaseDir,
    [string]$IssPath,
    [string]$Architecture = 'x64'
  )

  # Inno Setup 6.3+ architecture identifiers. 'arm64' produces a native ARM64
  # installer; 'x64compatible' keeps the original x64 behavior (also runnable on
  # ARM64 under x64 emulation).
  if ($Architecture -eq 'arm64') {
    $archesAllowed = 'arm64'
    $archesInstallIn64Bit = 'arm64'
  } else {
    $archesAllowed = 'x64compatible'
    $archesInstallIn64Bit = 'x64compatible'
  }

  $iss = @"
#define MyAppName "Voltix"
#define MyAppVersion "$AppVersion"
#define MyAppPublisher "Voltix"
#define MyAppExeName "voltix.exe"

[Setup]
AppId={{2B684544-2B56-47BE-B52F-6F7A94BCA4E1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Voltix
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=$OutputDir
OutputBaseFilename=$InstallerBaseName
SetupIconFile=$IconPath
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UsePreviousPrivileges=yes
ArchitecturesAllowed=$archesAllowed
ArchitecturesInstallIn64BitMode=$archesInstallIn64Bit

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "$ReleaseDir\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
"@

  Set-Content -Path $IssPath -Value $iss -Encoding UTF8
}

$flutterExe = Get-FlutterCommand
$isccExe = Get-IsccPath

Push-Location $repoRoot
try {
  if ($NoBump) {
    Write-Host "Skipping bump (-NoBump) - building at the current numbers." -ForegroundColor DarkGray
  } else {
    $bumped = Step-BuildNumbers
    if ($WhatIf) { return }
    $sharedVersionName = $bumped.Name
    $mobileVersionCode = $bumped.Mobile
    $tvVersionCode     = $bumped.Tv
  }

  Assert-VersionsMatchPubspec
  $appVersion = Get-AppVersion

  # x64 keeps the original "Voltix_Windows_v<version>" name; arm64 follows the same
  # scheme with a "WindowsARM64" platform token.
  if ($Architecture -eq 'arm64') {
    $installerBaseName = "Voltix_WindowsARM64_v$appVersion"
  } else {
    $installerBaseName = "Voltix - Entertainment without Limits"
  }

  Write-Host "Voltix version: $appVersion (target: $Architecture)"

  Assert-ToolchainVersions -FlutterExe $flutterExe

  # Checked before vcpkg, because vcpkg is the first thing that needs it and its
  # own error message does not name the real problem.
  Assert-VisualStudioCppWorkload -Architecture $Architecture
  Assert-NugetAvailable

  Initialize-LibarchiveForWindows -Triplet $vcpkgTriplet

  Write-Host "Cleaning previous Flutter outputs and CMake cache..."
  Invoke-CheckedCommand -Name "flutter clean" -FilePath $flutterExe -Arguments @("clean")
  $cmakeBuildDir = Join-Path $repoRoot "build\windows"
  $ephemeralDir = Join-Path $repoRoot "windows\flutter\ephemeral"
  if (Test-Path $cmakeBuildDir) { Remove-Item -Path $cmakeBuildDir -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path $ephemeralDir) { Remove-Item -Path $ephemeralDir -Recurse -Force -ErrorAction SilentlyContinue }

  Write-Host "Resolving Dart and Flutter packages..."
  Invoke-CheckedCommand -Name "flutter pub get" -FilePath $flutterExe -Arguments @("pub", "get")

  # Make sure Windows desktop is enabled and the engine artifacts are in the
  # Flutter SDK cache before CMake configures.
  #
  # This does NOT populate windows\flutter\ephemeral\ - the flutter_assemble
  # custom command copies cpp_client_wrapper\, the engine headers and
  # flutter_windows.dll into the project later, during the build itself. What
  # precache does is guarantee those artifacts exist in the SDK to be copied
  # from, so the build is not the first thing to discover they are absent.
  #
  # Both commands are idempotent and near-instant once cached.
  Write-Host "Ensuring Windows desktop artifacts are present..."
  Invoke-CheckedCommand -Name "flutter config --enable-windows-desktop" `
    -FilePath $flutterExe -Arguments @("config", "--enable-windows-desktop")
  Invoke-CheckedCommand -Name "flutter precache --windows" `
    -FilePath $flutterExe -Arguments @("precache", "--windows")

  # NOTE: do not assert on windows\flutter\ephemeral\cpp_client_wrapper here.
  # It is copied into the project by the flutter_assemble custom command DURING
  # the CMake build, not by precache - precache only fills the Flutter SDK's own
  # artifact cache. Checking for it before the build always fails.

  Write-Host "Building Windows $Architecture release..."
  Invoke-CheckedCommand -Name "flutter build windows" -FilePath $flutterExe -Arguments @("build", "windows", "--release", "--dart-define=DISTRIBUTION_CHANNEL=windows")

  $releaseDir = Join-Path $repoRoot "build\windows\$Architecture\runner\Release"
  $releaseExe = Join-Path $releaseDir "voltix.exe"
  if (-not (Test-Path $releaseExe)) {
    throw "Missing release binary: $releaseExe"
  }

  Copy-VcpkgRuntimeDlls -VcpkgRoot $env:VCPKG_ROOT -ReleaseDir $releaseDir -Triplet $vcpkgTriplet

  $outputDir = Join-Path $repoRoot "build\windows\installer"
  $iconPath = Join-Path $repoRoot "windows\runner\resources\app_icon.ico"
  $issPath = Join-Path $outputDir "voltix.generated.iss"
  $outputExe = Join-Path $outputDir "$installerBaseName.exe"
  $rootExe = Join-Path $repoRoot "$installerBaseName.exe"

  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

  if (-not (Test-Path $iconPath)) {
    throw "Missing app icon: $iconPath"
  }

  New-InnoScript -AppVersion $appVersion -InstallerBaseName $installerBaseName -OutputDir $outputDir -IconPath $iconPath -ReleaseDir $releaseDir -IssPath $issPath -Architecture $Architecture

  Write-Host "Building installer EXE..."
  Invoke-CheckedCommand -Name "ISCC" -FilePath $isccExe -Arguments @($issPath)

  if (-not (Test-Path $outputExe)) {
    throw "Installer not found at expected path: $outputExe"
  }

  Copy-Item -Path $outputExe -Destination $rootExe -Force

  $publishScript = Join-Path $repoRoot 'publish-release.ps1'
  $secretsScript = Join-Path $repoRoot 'build-secrets.ps1'
  if (Test-Path $secretsScript) { . $secretsScript }
  if (Test-Path $publishScript) {
    . $publishScript
    Write-Host "Publishing to release storage..."
    $variant = if ($Architecture -eq 'arm64') { 'ARM64' } else { '' }
    Publish-VoltixRelease -FilePath $outputExe -Version $appVersion -Variant $variant | Out-Null
  }

  Write-Host "Installer created:" $outputExe
  Write-Host "Installer copied to root:" $rootExe
}
finally {
  Pop-Location
}