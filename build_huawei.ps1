# build_huawei.ps1 - builds the Huawei AppGallery APK.
#
# An ordinary Android mobile APK: no HMS dependency, no separate flavor, same
# keystore and same applicationId as the Play build. The ONLY difference is the
# distribution channel, and that difference matters - see below.
#
# Usage:
#   .\build_huawei.ps1
#   .\build_huawei.ps1 -AppGalleryAppId C123456789
#
# Unlike its siblings this script does not pin version constants. It has no
# second source of truth to drift from: Gradle reads the version straight out of
# pubspec.yaml, so there is nothing here to keep in step. It reads pubspec purely
# to name the output file and print what it built.
[CmdletBinding()]
param(
    # Listing id from AppGallery Connect. Optional - without it the in-app update
    # prompt still opens AppGallery via appmarket://, it just cannot fall back to
    # an https listing URL. That fallback rarely matters on a Huawei device.
    [string] $AppGalleryAppId = ''
)

$ErrorActionPreference = 'Stop'

# Build-time secrets, shared with the other Android build scripts.
$publishScript = Join-Path $PSScriptRoot 'publish-release.ps1'
if (Test-Path $publishScript) { . $publishScript }
$sasConfig = Join-Path $PSScriptRoot 'build-secrets.ps1'
if (Test-Path $sasConfig) { . $sasConfig }
if (Get-Command Write-AzureSasStatus -ErrorAction SilentlyContinue) { Write-AzureSasStatus }

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-FlutterBin {
    $onPath = Get-Command flutter -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = @(
        "$env:LOCALAPPDATA\flutter\bin\flutter.bat",
        "$env:USERPROFILE\flutter\bin\flutter.bat",
        "C:\dev\flutter\bin\flutter.bat",
        "C:\flutter\bin\flutter.bat",
        "C:\src\flutter\bin\flutter.bat"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    throw "Flutter not found. Put it on PATH, or install to one of:`n  $($candidates -join "`n  ")"
}

$flutterBin = Resolve-FlutterBin

# Same clean sequence as the other Android scripts: the Gradle daemon holds
# handles under build\ on Windows, so stopping it first is what makes the clean
# actually complete. See the note in build_aab.ps1.
function Invoke-CleanBuildTree {
    $gradlew = Join-Path $repoRoot 'android\gradlew.bat'
    if (Test-Path $gradlew) {
        Push-Location (Join-Path $repoRoot 'android')
        try {
            Write-Host "0. Stopping Gradle daemon..."
            & cmd /c "gradlew.bat --stop" 2>&1 | Out-Null
        } finally { Pop-Location }
    }

    Write-Host "1. flutter clean..."
    & $flutterBin clean
    if ($LASTEXITCODE -ne 0) {
        throw "flutter clean failed (exit $LASTEXITCODE) - refusing to build on a partially cleaned tree."
    }

    $buildDir = Join-Path $repoRoot 'build'
    if (Test-Path $buildDir) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $buildDir) {
            throw "Could not fully remove $buildDir - something holds a file handle (Gradle daemon, Android Studio, antivirus)."
        }
    }

    Write-Host "2. flutter pub get..."
    & $flutterBin pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed (exit $LASTEXITCODE)" }

    $packageConfig = Join-Path $repoRoot '.dart_tool\package_config.json'
    if (-not (Test-Path $packageConfig)) {
        Write-Host "   package_config.json missing after pub get - retrying..." -ForegroundColor Yellow
        & $flutterBin pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get retry failed (exit $LASTEXITCODE)" }
    }
    if (-not (Test-Path $packageConfig)) {
        throw "$packageConfig still missing after two pub get runs. Try: flutter pub get --verbose"
    }
}

function Get-PubspecVersion {
    $pubspec = Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:[ \t]*([0-9][^+\s]*)\+([0-9]+)[ \t]*\r?$') {
        throw "pubspec.yaml 'version:' is not in x.y.z+build form."
    }
    return @{ Name = $Matches[1]; Code = $Matches[2] }
}

Push-Location $repoRoot
try {
    $v = Get-PubspecVersion
    Write-Host "Voltix AppGallery build - $($v.Name) (code $($v.Code))" -ForegroundColor Cyan
    Write-Host "  flutter: $flutterBin"
    if ($AppGalleryAppId) {
        Write-Host "  AppGallery listing id: $AppGalleryAppId"
    } else {
        Write-Host "  No -AppGalleryAppId given; update prompt will use appmarket:// only." -ForegroundColor DarkGray
    }

    Invoke-CleanBuildTree

    # DISTRIBUTION_CHANNEL=huawei is load-bearing, not cosmetic. It is what makes
    # AppDistribution.isAppGalleryBuild true, which blocks APK self-update.
    # AppGallery prohibits updating outside the store, exactly as Play does.
    # Omit it and the channel resolves to `unknown`, which falls back to
    # Platform.isAndroid and re-enables self-update - grounds for rejection, and
    # if it slipped through, AppGallery's record of the installed version would
    # drift from reality.
    # All defines go through --dart-define-from-file. Passed on the command line,
    # the Azure SAS tokens' '&' characters reached cmd.exe (flutter is a .bat)
    # and were run as commands - "'st' is not recognized..." - failing the build
    # after the APK had already compiled.
    $defineMap = [ordered]@{ DISTRIBUTION_CHANNEL = 'huawei' }
    if ($AppGalleryAppId) { $defineMap['APPGALLERY_APP_ID'] = $AppGalleryAppId }
    if (Get-Command Get-BuildSecretDefinePairs -ErrorAction SilentlyContinue) {
        foreach ($pair in Get-BuildSecretDefinePairs) {
            $idx = $pair.IndexOf('=')
            if ($idx -gt 0) { $defineMap[$pair.Substring(0, $idx)] = $pair.Substring($idx + 1) }
        }
    }
    $defineFile = Join-Path ([IO.Path]::GetTempPath()) "voltix-huawei-defines-$PID.json"
    # No BOM: Windows PowerShell's -Encoding UTF8 writes one, which the JSON
    # reader rejects.
    [IO.File]::WriteAllText($defineFile, ($defineMap | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    $dartDefines = @("--dart-define-from-file=$defineFile")

    Write-Host "3. Building AppGallery APK..."
    & $flutterBin build apk --flavor mobile --release @dartDefines
    $buildExit = $LASTEXITCODE
    Remove-Item -LiteralPath $defineFile -Force -ErrorAction SilentlyContinue
    if ($buildExit -ne 0) { throw "flutter build apk failed (exit $buildExit)" }

    $built = Get-ChildItem -Path (Join-Path $repoRoot 'build\app\outputs') -Recurse -File `
        -Filter "app-mobile-release.apk" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $built) { throw "Built APK not found under build\app\outputs" }

    # Named distinctly so an AppGallery build is never confused with the Play or
    # sideload artifacts - they are byte-different despite the same version.
    $outName = "Voltix-AppGallery-v$($v.Name).apk"
    foreach ($d in @((Join-Path $repoRoot $outName), (Join-Path $repoRoot "..\$outName"))) {
        Copy-Item $built.FullName $d -Force
    }

    if (Get-Command Publish-VoltixRelease -ErrorAction SilentlyContinue) {
        Write-Host "4. Publishing to release storage..."
        Publish-VoltixRelease -FilePath $built.FullName -Version $v.Name -Variant 'Huawei' | Out-Null
    }

    Write-Host ""
    Write-Host "SUCCESS - $outName" -ForegroundColor Green
    Write-Host "  $($built.FullName)"
    Write-Host "  Upload to AppGallery Connect -> My apps -> your app -> Version."
}
finally { Pop-Location }
