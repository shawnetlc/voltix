# build_aab.ps1 - builds ONLY the AAB (App Bundle) files via Gradle directly.
#
# Bumps the BUILD NUMBERS on every run, before building. The versionName is left
# alone - it is the marketing version and belongs to a release decision, not to
# a build. Play requires a unique ascending versionCode per uploaded artifact, so
# producing two AABs with the same code is never useful: the second can only be
# rejected.
#
# Pass -NoBump to rebuild at the current numbers.
#
# Usage:
#   .\build_aab.ps1              # bump codes, then build
#   .\build_aab.ps1 -NoBump      # rebuild at the current codes
#   .\build_aab.ps1 -WhatIf      # show the numbers it would use, change nothing
[CmdletBinding()]
param(
    [switch] $NoBump,
    [switch] $WhatIf
)

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
# Rewritten in place by Step-BuildNumbers below, and by deploy-app.ps1. Still
# asserted against pubspec.yaml before building, so a hand-edit that desyncs
# them fails loudly rather than stamping one version while checking another.
$sharedVersionName = "1.6.24"
$mobileVersionCode = "40000187"
$tvVersionCode     = "40000188"

function Read-Utf8([string] $Path) { Get-Content -LiteralPath $Path -Raw }

# UTF-8 without BOM: a BOM in pubspec.yaml breaks the Gradle parser that reads
# `version:` straight out of it.
function Write-Utf8([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Advances versionName patch and build numbers, and writes them everywhere they are held.
#
# Codes move in steps of 2, keeping the mobile/TV pairing even-then-odd with TV
# exactly one above mobile. That pairing is a convention this project already
# relies on (see the history in pubspec.yaml) and build_custom.ps1 hard-fails if
# TV is not above mobile.
#
# Reads the CURRENT numbers from pubspec rather than from the pins above, so it
# stays correct even if the pins have drifted.
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

    # Advance versionName patch component (e.g. 1.16.2 -> 1.16.3)
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
        Write-Host "WHATIF - would bump version and build codes:" -ForegroundColor Yellow
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
            throw "$($check.Label) in build_aab.ps1 does not match pubspec.yaml - update both before building."
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

function Invoke-Gradle([string]$task, [string]$channel) {
    $dd = Encode-DartDefines @("DISTRIBUTION_CHANNEL=$channel")
    Push-Location "$repoRoot\android"
    try {
        & ".\gradlew.bat" ":app:$task" "-Pdart-defines=$dd" "-Ptarget-platform=android-arm64,android-arm,android-x64" --stacktrace
        if ($LASTEXITCODE -ne 0) { throw "Gradle task $task failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

Push-Location $repoRoot
try {
    if ($NoBump) {
        Write-Host "Skipping bump (-NoBump) - building at the current numbers." -ForegroundColor DarkGray
    }
    else {
        $bumped = Step-BuildNumbers
        if ($WhatIf) { return }
        # Use what was actually written, so the assertion below checks the new
        # numbers rather than the stale literals this run started with.
        $sharedVersionName = $bumped.Name
        $mobileVersionCode = $bumped.Mobile
        $tvVersionCode     = $bumped.Tv
    }

    Assert-VersionsMatchPubspec
    Invoke-CleanBuildTree

    Write-Host "3. Android TV release AAB (Gradle)..."
    Invoke-Gradle "assembleAndroidTvRelease" "android_tv_aab"
    Invoke-Gradle "bundleAndroidTvRelease" "android_tv_aab"
    $tvAab = Find-Artifact "app-androidtv-release.aab"
    if (-not $tvAab) { throw "Android TV AAB not found under $($outputsRoots -join ', ')" }
    Write-Host "   -> $tvAab" -ForegroundColor Green
    foreach ($d in @("$repoRoot\VoltixTest-AndroidTV.aab","$repoRoot\..\VoltixTest-AndroidTV.aab")) {
        Copy-Item $tvAab $d -Force
    }

    Write-Host "4. Mobile release AAB (Gradle)..."
    Invoke-Gradle "assembleMobileRelease" "mobile_aab"
    Invoke-Gradle "bundleMobileRelease" "mobile_aab"
    $mobileAab = Find-Artifact "app-mobile-release.aab"
    if (-not $mobileAab) { throw "Mobile AAB not found under $($outputsRoots -join ', ')" }
    Write-Host "   -> $mobileAab" -ForegroundColor Green
    foreach ($d in @("$repoRoot\VoltixTest-Mobile.aab","$repoRoot\..\VoltixTest-Mobile.aab")) {
        Copy-Item $mobileAab $d -Force
    }

    Write-Host "SUCCESS! AAB files built and copied successfully." -ForegroundColor Green
}
finally { Pop-Location }
