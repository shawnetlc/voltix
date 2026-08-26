# build_custom.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = "C:\Users\ShawneBedford\Downloads\Voltix-tree-IN-PROGRESS-2.5.0-merge\voltixsource-main"
$parentDir = "C:\Users\ShawneBedford\Downloads\Voltix-tree-IN-PROGRESS-2.5.0-merge"
Push-Location "C:\vx"

try {
    # 1. Parse pubspec.yaml for versions
    $pubspecContent = Get-Content "C:\vx\pubspec.yaml" -Raw
    
    if ($pubspecContent -match 'version:\s*([^\s+]+)\+(\d+)') {
        $mobileBuildName = $matches[1]
        $mobileBuildNumber = $matches[2]
    } else {
        throw "Could not parse version from pubspec.yaml"
    }

    if ($pubspecContent -match 'android_tv_build_number:\s*(\d+)') {
        $tvBuildNumber = $matches[1]
        $tvBuildName = $mobileBuildName
    } else {
        throw "Could not parse android_tv_build_number from pubspec.yaml"
    }

    Write-Host "Building Mobile: Version $mobileBuildName, Build $mobileBuildNumber" -ForegroundColor Cyan
    Write-Host "Building Android TV: Version $tvBuildName, Build $tvBuildNumber" -ForegroundColor Cyan

    $tvApkSource = "C:\vx\build\app\outputs\flutter-apk\app-androidtv-release.apk"
    $mobileApkSource = "C:\vx\build\app\outputs\flutter-apk\app-mobile-release.apk"

    if (Test-Path $tvApkSource) { Remove-Item $tvApkSource -Force }
    if (Test-Path $mobileApkSource) { Remove-Item $mobileApkSource -Force }

    # 2. Building Android TV release APK
    Write-Host "1. Building Android TV release APK..." -ForegroundColor Yellow
    flutter build apk --release --flavor androidTv --build-name "$tvBuildName" --build-number "$tvBuildNumber" --dart-define=DISTRIBUTION_CHANNEL=android_tv_apk
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $tvApkSource)) {
        throw "Flutter build Android TV APK failed with exit code $LASTEXITCODE"
    }

    Copy-Item -Path $tvApkSource -Destination "$parentDir\VoltixTest-AndroidTV.apk" -Force
    Copy-Item -Path $tvApkSource -Destination "$parentDir\VoltixTest.apk" -Force
    Copy-Item -Path $tvApkSource -Destination "$parentDir\Voltix-Streaming-AndroidTV.apk" -Force
    Copy-Item -Path $tvApkSource -Destination "$parentDir\app-androidtv-release.apk" -Force
    Write-Host "Android TV APK successfully built and copied!" -ForegroundColor Green

    # 3. Building Mobile release APK
    Write-Host "2. Building Mobile release APK..." -ForegroundColor Yellow
    flutter build apk --release --flavor mobile --build-name "$mobileBuildName" --build-number "$mobileBuildNumber" --dart-define=DISTRIBUTION_CHANNEL=apk
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $mobileApkSource)) {
        throw "Flutter build Mobile APK failed with exit code $LASTEXITCODE"
    }

    Copy-Item -Path $mobileApkSource -Destination "$parentDir\VoltixTest-Mobile.apk" -Force
    Copy-Item -Path $mobileApkSource -Destination "$parentDir\Voltix-Streaming-Mobile.apk" -Force
    Copy-Item -Path $mobileApkSource -Destination "$parentDir\app-mobile-release.apk" -Force
    Write-Host "Mobile APK successfully built and copied!" -ForegroundColor Green

    Write-Host "SUCCESS! Both Android TV and Mobile release APKs built and updated successfully!" -ForegroundColor Green
}
finally {
    Pop-Location
}

