# build_apk.ps1 - builds ONLY the APK files via Gradle directly.
$ErrorActionPreference = 'Stop'

# Flutter from PATH first, then the usual install locations. This was hardcoded
# to C:\dev\flutter\bin\flutter.bat, so the script only ran on one machine.
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

# Build-time secrets (Azure SAS tokens, Grok credentials), shared by every
# Android build script so there is one place to rotate them.
$sasConfig = Join-Path $PSScriptRoot 'build-secrets.ps1'
if (Test-Path $sasConfig) {
    . $sasConfig
} else {
    Write-Host "build-secrets.ps1 not found - builds will use the sync proxy" -ForegroundColor Yellow
    $AzureBlobSasToken = ''
    $AzureBlobSettingsSasToken = ''
}
if (Get-Command Write-AzureSasStatus -ErrorAction SilentlyContinue) { Write-AzureSasStatus }

$publishScript = Join-Path $PSScriptRoot 'publish-release.ps1'
if (Test-Path $publishScript) { . $publishScript }

$flutterBin = Resolve-FlutterBin
# Resolved from this script's own location so the checkout can live anywhere.
# Previously hardcoded to C:\VoltixNew-2.2.0-upgrade\merge, which broke as soon
# as the folder was renamed, moved, or cloned by anyone else.
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputsRoots = @(
    "$repoRoot\build\app\outputs",
    "$repoRoot\android\build\app\outputs"
)

# -- Versions for this build ------------------------------------------------
$sharedVersionName = "2.0.62"
$mobileVersionCode = "40000420"
$tvVersionCode     = "40000421"

function Assert-VersionsMatchPubspec {
    $pubspec = Get-Content "$repoRoot\pubspec.yaml" -Raw
    $checks = @(
        @{ Label = 'shared version + mobile code'; Pattern = "(?m)^version:\s*$([regex]::Escape($sharedVersionName))\+$mobileVersionCode\s*$" },
        @{ Label = 'TV build number';              Pattern = "(?m)^\s*android_tv_build_number:\s*$tvVersionCode\s*$" }
    )
    foreach ($check in $checks) {
        if ($pubspec -notmatch $check.Pattern) {
            throw "$($check.Label) in build_apk.ps1 does not match pubspec.yaml - update both before building."
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

function Encode-DartDefines([string[]]$defs) {
    ($defs | ForEach-Object {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_))
    }) -join ','
}

function Find-Artifact([string]$namePattern) {
    $roots = $outputsRoots | Where-Object { Test-Path $_ }
    if (-not $roots) { return $null }
    $hit = Get-ChildItem -Path $roots -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $namePattern } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# Stops the Gradle daemon, then cleans - in that order, deliberately.
#
# On Windows the daemon keeps file handles open under build\. `flutter clean`
# then fails to delete parts of the tree and, because `& $flutterBin clean` does
# not throw on a non-zero native exit code, the build carried on against a
# half-deleted tree. That produces failures that look nothing like their cause:
# D8 reporting NoSuchFileException for a .transforms path, or DexMergingTask
# complaining that desugar*FileDependencies does not exist.
function Invoke-CleanBuildTree {
    $gradlew = Join-Path $repoRoot 'android\gradlew.bat'
    if (Test-Path $gradlew) {
        Push-Location (Join-Path $repoRoot 'android')
        try {
            Write-Host "0. Stopping Gradle daemon (releases locks on build\)..."
            & cmd /c "gradlew.bat --stop" 2>&1 | Out-Null
        } finally { Pop-Location }
    }

    Write-Host "1. flutter clean..."
    & $flutterBin clean
    if ($LASTEXITCODE -ne 0) {
        throw "flutter clean failed (exit $LASTEXITCODE) - refusing to build on a partially cleaned tree."
    }

    # flutter clean can report success while leaving directories behind if a
    # handle was still open. Verify, and remove what survived.
    $buildDir = Join-Path $repoRoot 'build'
    if (Test-Path $buildDir) {
        Write-Host "   build\ survived flutter clean - removing directly..."
        Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $buildDir) {
            throw @"
Could not fully remove $buildDir.

Something is holding a file handle. Usual suspects: a running Gradle daemon, an
open Android Studio, or on-access antivirus scanning. Close them and retry, or
delete the folder manually.
"@
        }
    }

    Write-Host "2. flutter pub get..."
    & $flutterBin pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed (exit $LASTEXITCODE)"
    }

    # Gradle shells out to `flutter assemble`, which reads this file. If it is
    # absent the build dies mid-way with "package_config.json does not exist",
    # taking gen_localizations and gen_dart_plugin_registrant down with it - an
    # error that names the file but not the reason.
    #
    # pub get can report success and still leave it missing when the tree was
    # fully cold. One retry costs seconds and clears it.
    $packageConfig = Join-Path $repoRoot '.dart_tool\package_config.json'
    if (-not (Test-Path $packageConfig)) {
        Write-Host "   package_config.json missing after pub get - retrying..." -ForegroundColor Yellow
        & $flutterBin pub get
        if ($LASTEXITCODE -ne 0) {
            throw "flutter pub get retry failed (exit $LASTEXITCODE)"
        }
    }
    if (-not (Test-Path $packageConfig)) {
        throw @"
$packageConfig still does not exist after two pub get runs.

Gradle invokes 'flutter assemble', which cannot run without it. Try from this
directory:
  flutter pub get --verbose
"@
    }
    Write-Host "   package_config.json OK" -ForegroundColor DarkGray
}

# android/.gitignore excludes gradlew, gradlew.bat and gradle-wrapper.jar, so a
# fresh clone (or anything that pruned the android tree) arrives without the
# Gradle wrapper and the build dies on "gradlew.bat is not recognized".
# 'flutter create --platforms=android .' restores exactly those template files
# without touching existing sources.
function Assert-GradleWrapper {
    $wrapperBat = Join-Path $repoRoot 'android\gradlew.bat'
    $wrapperJar = Join-Path $repoRoot 'android\gradle\wrapper\gradle-wrapper.jar'
    if ((Test-Path $wrapperBat) -and (Test-Path $wrapperJar)) {
        Write-Host "   Gradle wrapper OK" -ForegroundColor DarkGray
        return
    }

    Write-Host "   Gradle wrapper missing - restoring via flutter create..." -ForegroundColor Yellow
    Push-Location $repoRoot
    try {
        & $flutterBin create --platforms=android .
        if ($LASTEXITCODE -ne 0) { throw "flutter create failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }

    if (-not (Test-Path $wrapperBat) -or -not (Test-Path $wrapperJar)) {
        throw @"
Gradle wrapper still missing after 'flutter create --platforms=android .'.

Restore it one of these ways, then re-run this script:
  * copy gradlew, gradlew.bat and gradle/wrapper/gradle-wrapper.jar from
    another Flutter project's android folder
  * with Gradle installed:  cd android; gradle wrapper --gradle-version 8.14.3
"@
    }
    Write-Host "   Gradle wrapper restored" -ForegroundColor DarkGray
}

function Invoke-Gradle([string]$task, [string]$channel) {
    # Encode-DartDefines base64s each entry separately, so the SAS's '&'
    # characters pass through untouched - no quoting or escaping needed.
    $defines = @("DISTRIBUTION_CHANNEL=$channel")
    if (Get-Command Get-BuildSecretDefinePairs -ErrorAction SilentlyContinue) {
        $defines += Get-BuildSecretDefinePairs
    }
    $dd = Encode-DartDefines $defines
    Push-Location "$repoRoot\android"
    try {
        & ".\gradlew.bat" ":app:$task" "-Pdart-defines=$dd" "-Ptarget-platform=android-arm64,android-arm,android-x64" --stacktrace
        if ($LASTEXITCODE -ne 0) { throw "Gradle task $task failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

Push-Location $repoRoot
try {
    Assert-VersionsMatchPubspec
    Invoke-CleanBuildTree
    Assert-GradleWrapper

    Write-Host "3. Android TV release APK (Gradle)..."
    Invoke-Gradle "assembleAndroidTvRelease" "android_tv_apk"
    $tvApk = Find-Artifact "app-androidtv-release.apk"
    if (-not $tvApk) { throw "Android TV APK not found under $($outputsRoots -join ', ')" }
    Write-Host "   -> $tvApk" -ForegroundColor Green
    foreach ($d in @(
        "$repoRoot\VoltixTest-AndroidTV.apk",
        "$repoRoot\Voltix-Streaming-AndroidTV.apk",
        "$repoRoot\..\VoltixTest-AndroidTV.apk",
        "$repoRoot\..\Voltix-Streaming-AndroidTV.apk"
    )) {
        Copy-Item $tvApk $d -Force
    }

    Write-Host "4. Mobile release APK (Gradle)..."
    Invoke-Gradle "assembleMobileRelease" "apk"
    $mobileApk = Find-Artifact "app-mobile-release.apk"
    if (-not $mobileApk) { throw "Mobile APK not found under $($outputsRoots -join ', ')" }
    Write-Host "   -> $mobileApk" -ForegroundColor Green
    foreach ($d in @(
        "$repoRoot\VoltixTest-Mobile.apk",
        "$repoRoot\Voltix-Streaming-Mobile.apk",
        "$repoRoot\..\VoltixTest-Mobile.apk",
        "$repoRoot\..\Voltix-Streaming-Mobile.apk"
    )) {
        Copy-Item $mobileApk $d -Force
    }

    if (Get-Command Publish-VoltixRelease -ErrorAction SilentlyContinue) {
        Write-Host "5. Publishing to release storage..."
        Publish-VoltixRelease -FilePath $mobileApk -Version $sharedVersionName | Out-Null
        Publish-VoltixRelease -FilePath $tvApk -Version $sharedVersionName -Variant 'TV' | Out-Null
    }

    Write-Host "SUCCESS! APK files built and copied successfully." -ForegroundColor Green
}
finally { Pop-Location }
