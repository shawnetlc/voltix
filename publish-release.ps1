# publish-release.ps1 - uploads a finished build to Azure Blob Storage so the
# website's Download menu and page offer it straight away.
#
# Dot-sourced by build_apk.ps1, build_huawei.ps1 and build-windows.ps1. Files
# are named  Voltix_<version>[_<Variant>].<ext> :
#   Voltix_2.0.62.apk          Android phones & tablets
#   Voltix_2.0.62_TV.apk       Android TV / Google TV
#   Voltix_2.0.62_Huawei.apk   Huawei (AppGallery build)
#   Voltix_2.0.62.exe          Windows (x64) installer
#   Voltix_2.0.62_ARM64.exe    Windows (ARM64) installer
# The website lists the container and always shows the newest version of each.
#
# Needs a SAS URL for the releases container with Create + Write permission:
#   https://<account>.blob.core.windows.net/voltix-releases?sv=...&sig=...
# set as $VoltixReleasesSasUrl in build-secrets.ps1, or in the environment as
# VOLTIX_RELEASES_SAS_URL. Without one the upload is skipped (build still
# succeeds). Set VOLTIX_SKIP_RELEASE_UPLOAD=1 to skip it on purpose.

function Get-VoltixReleasesSasUrl {
    if ($env:VOLTIX_RELEASES_SAS_URL) { return $env:VOLTIX_RELEASES_SAS_URL }
    $var = Get-Variable -Name VoltixReleasesSasUrl -Scope Global -ErrorAction SilentlyContinue
    if ($var -and $var.Value) { return [string]$var.Value }
    $var = Get-Variable -Name VoltixReleasesSasUrl -ErrorAction SilentlyContinue
    if ($var -and $var.Value) { return [string]$var.Value }
    return ''
}

function Publish-VoltixRelease {
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [Parameter(Mandatory = $true)] [string] $Version,
        [string] $Variant = ''
    )

    if ($env:VOLTIX_SKIP_RELEASE_UPLOAD -eq '1') {
        Write-Host "   Release upload skipped (VOLTIX_SKIP_RELEASE_UPLOAD=1)" -ForegroundColor DarkGray
        return $null
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Warning "Release upload skipped: $FilePath not found"
        return $null
    }

    $sasUrl = Get-VoltixReleasesSasUrl
    if (-not $sasUrl -or $sasUrl -notmatch '\?') {
        Write-Warning "Release upload skipped: no releases SAS URL. Set `$VoltixReleasesSasUrl in build-secrets.ps1 or VOLTIX_RELEASES_SAS_URL."
        return $null
    }

    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $cleanVersion = ($Version -split '\+')[0].Trim().TrimStart('v', 'V')
    $suffix = if ($Variant) { "_$Variant" } else { '' }
    $blobName = "Voltix_$cleanVersion$suffix$ext"

    $q = $sasUrl.IndexOf('?')
    $containerUrl = $sasUrl.Substring(0, $q).TrimEnd('/')
    $sas = $sasUrl.Substring($q)
    $target = "$containerUrl/$blobName$sas"

    $contentType = switch ($ext) {
        '.apk' { 'application/vnd.android.package-archive' }
        '.exe' { 'application/vnd.microsoft.portable-executable' }
        default { 'application/octet-stream' }
    }

    $sizeMb = [math]::Round((Get-Item -LiteralPath $FilePath).Length / 1MB, 1)
    Write-Host "   Uploading $blobName ($sizeMb MB) to release storage..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{
            'x-ms-blob-type'               = 'BlockBlob'
            'x-ms-version'                 = '2021-08-06'
            'x-ms-blob-content-type'       = $contentType
            'x-ms-blob-content-disposition' = "attachment; filename=`"$blobName`""
        }
        Invoke-WebRequest -Method Put -Uri $target -InFile $FilePath -Headers $headers `
            -ContentType $contentType -UseBasicParsing -TimeoutSec 3600 | Out-Null
        Write-Host "   -> uploaded $blobName (live on the website's Download page within ~2 minutes)" -ForegroundColor Green
        return $blobName
    } catch {
        # Never fail the build over the upload - the artifact is already built.
        Write-Warning "Release upload of $blobName failed: $($_.Exception.Message)"
        return $null
    }
}
