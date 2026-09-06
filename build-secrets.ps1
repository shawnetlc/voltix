# build-secrets.ps1 - the build-time values every Android build embeds.
#
# Dot-sourced by build_apk.ps1, build_aab.ps1, build_huawei.ps1 and
# build-android.ps1 so there is ONE place to rotate them. Four copies of a
# token that expires would mean four places to forget.
#
# A SAS is scoped to a single container, so there are two:
#
#   $AzureBlobSasToken          -> voltix-taste-profiles
#   $AzureBlobSettingsSasToken  -> voltix-user-settings
#                                  (also holds watch history, under a path
#                                   prefix rather than its own container)
#
# Both expire 2027-06-01. When they lapse the app does not error: it reports
# itself unconfigured and falls back to the /api/voltix/azure-sync proxy, so
# everything keeps working and nobody notices. Diarise the date.
#
# To rotate, against the container and NOT the account:
#   az storage container generate-sas --account-name voltixstorage `
#     --name voltix-taste-profiles --permissions racw `
#     --expiry 2028-06-01 --https-only --output tsv
#
# Never put an account key here. Nothing in the app signs with one, and it
# would grant whoever unpacked the APK full read/write/delete over every
# user's profile, settings and watch history.
#
# Single-quoted on purpose: PowerShell does not interpolate inside '...', and
# these contain $ and & characters.
#
# An environment variable of the same name overrides the baked-in value, which
# is how CI supplies its own without editing this file.

# voltix-taste-profiles - read/add/create/write
$AzureBlobSasToken = 'sp=racw&st=2026-09-05T23:29:08Z&se=2027-06-01T07:44:08Z&spr=https&sv=2026-02-06&sr=c&sig=NWIl1HJ3UgLprg%2FYNCfyXUtbQNbHpeUzgRXpqyQ9utc%3D'
if ($env:AZURE_BLOB_SAS_TOKEN) { $AzureBlobSasToken = $env:AZURE_BLOB_SAS_TOKEN }

# voltix-user-settings - read/add/create/write/delete.
# Delete is here because the app offers "delete all cloud data", which removes
# the settings and watch-history blobs directly.
$AzureBlobSettingsSasToken = 'sp=racwd&st=2026-09-06T00:12:40Z&se=2027-06-01T08:27:40Z&spr=https&sv=2026-02-06&sr=c&sig=ZyhRWCNCM9WjR65nu9QBNgXYD9IkXyzrQJuAMm2Z86o%3D'
if ($env:AZURE_BLOB_SETTINGS_SAS_TOKEN) { $AzureBlobSettingsSasToken = $env:AZURE_BLOB_SETTINGS_SAS_TOKEN }

# ── Grok / xAI ──────────────────────────────────────────────────────────────
#
# Read by GrokTasteAiService, which already resolves these in this order:
# runtime override, then compile-time define, then the user's own key from
# Settings, then the process environment. A baked-in key therefore takes
# priority over whatever a user has entered - which is the intent for a
# shipped build, but worth knowing if you are testing with your own key.
#
# Leave empty and the AI features fall back to the built-in offline synthesis
# engine, which is a working state rather than a broken one.
$GrokApiKey = 'xai-AYt8URqAiDKxJZoWlkSbVuGYfMJZra3QJtif4DT1OyCF8mp4qlYG9OzXwSRiFMGfShU4HugB4a5OZopQ'
if ($env:GROK_API_KEY) { $GrokApiKey = $env:GROK_API_KEY }

# Pinned here rather than left to GrokTasteAiService.defaultModel, which is
# still 'grok-2-latest'. Shipped builds use this value; anything reading the
# in-app default (or a user's saved preference) will not match, so change both
# if the shipped model moves.
$GrokModel = 'grok-4.20-0309-non-reasoning'
if ($env:GROK_MODEL) { $GrokModel = $env:GROK_MODEL }

# Optional. Defaults to https://api.x.ai/v1/chat/completions when unset.
$GrokEndpoint = ''
if ($env:GROK_ENDPOINT) { $GrokEndpoint = $env:GROK_ENDPOINT }

# Returns the tokens as --dart-define arguments, for scripts that call
# `flutter build` directly.
function Get-AzureSasDartDefines {
    return (Get-BuildSecretDefinePairs | ForEach-Object { "--dart-define=$_" })
}

# Returns them as bare NAME=VALUE pairs, for scripts that go through Gradle's
# -Pdart-defines (which base64-encodes each entry itself).
function Get-BuildSecretDefinePairs {
    $pairs = @()
    if ($AzureBlobSasToken) {
        $pairs += "AZURE_BLOB_SAS_TOKEN=$AzureBlobSasToken"
    }
    if ($AzureBlobSettingsSasToken) {
        $pairs += "AZURE_BLOB_SETTINGS_SAS_TOKEN=$AzureBlobSettingsSasToken"
    }
    if ($GrokApiKey)   { $pairs += "GROK_API_KEY=$GrokApiKey" }
    if ($GrokModel)    { $pairs += "GROK_MODEL=$GrokModel" }
    if ($GrokEndpoint) { $pairs += "GROK_ENDPOINT=$GrokEndpoint" }
    return $pairs
}

# Back-compat alias for the Azure-only name.
function Get-AzureSasDefinePairs { return Get-BuildSecretDefinePairs }

function Write-AzureSasStatus {
    if ($AzureBlobSasToken) {
        Write-Host "Azure SAS (taste profiles): supplied" -ForegroundColor DarkGray
    } else {
        Write-Host "Azure SAS (taste profiles): not set - using the sync proxy" -ForegroundColor DarkGray
    }
    if ($AzureBlobSettingsSasToken) {
        Write-Host "Azure SAS (user settings):  supplied" -ForegroundColor DarkGray
    } else {
        Write-Host "Azure SAS (user settings):  not set - using the sync proxy" -ForegroundColor DarkGray
    }
    if ($GrokApiKey) {
        $modelNote = if ($GrokModel) { $GrokModel } else { "default model" }
        Write-Host "Grok:                       supplied ($modelNote)" -ForegroundColor DarkGray
    } else {
        Write-Host "Grok:                       not set - offline synthesis only" -ForegroundColor DarkGray
    }
}
