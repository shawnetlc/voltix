# deploy-web-client.ps1 - builds the Voltix web client and deploys it to
# www.voltixstudio.com/moonfin/ (the "Web Client" item under Stream Now).
#
#   .\deploy-web-client.ps1            # build, copy into the website, commit, push (deploys)
#   .\deploy-web-client.ps1 -NoPush    # build and copy only; review, then commit/push yourself
#
# SECURITY: build-secrets.ps1 is deliberately NOT loaded. Anything passed with
# --dart-define is compiled into main.dart.js, which every visitor downloads.
# Without the secrets the web app uses the backend's sync proxy instead.
[CmdletBinding()]
param(
    [string] $Website = 'C:\Voltix\voltixstudio',
    [switch] $NoPush
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$target   = Join-Path $Website 'client\public\moonfin'

if (-not (Test-Path (Join-Path $Website '.git'))) { throw "Website repo not found at $Website" }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'flutter is not on PATH' }

Push-Location $repoRoot
try {
    Write-Host "`n1/4  flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE) { throw 'flutter pub get failed' }

    Write-Host "`n2/4  flutter build web (base href /moonfin/, no secrets)" -ForegroundColor Cyan
    flutter build web --release --base-href /moonfin/ --dart-define=DISTRIBUTION_CHANNEL=web
    if ($LASTEXITCODE) { throw 'flutter build web failed' }
    $out = Join-Path $repoRoot 'build\web'
    if (-not (Test-Path (Join-Path $out 'main.dart.js'))) { throw "No main.dart.js in $out" }
} finally { Pop-Location }

Write-Host "`n3/4  Copy build\web -> $target" -ForegroundColor Cyan
# /MIR replaces the old Moonfin 1.4.0 build completely (stale files removed).
robocopy $out $target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
Write-Host "   $((Get-Content (Join-Path $target 'version.json') -Raw).Trim())" -ForegroundColor DarkGray

if ($NoPush) {
    Write-Host "`nBuilt and copied. Review in $Website, then commit and push to deploy." -ForegroundColor Yellow
    return
}

Write-Host "`n4/4  Commit + push (GitHub Actions deploys to voltixprd)" -ForegroundColor Cyan
Push-Location $Website
try {
    git add client/public/moonfin client/src/components/Navbar.tsx .github/workflows/azure-deploy.yml .github/workflows/main_voltixprd.yml
    git commit -m "Web Client: rebuild from current app (Voltix login, direct server) and show in Stream Now"
    if ($LASTEXITCODE) { throw 'git commit failed (nothing to commit?)' }
    git push origin main
    if ($LASTEXITCODE) { throw 'git push failed' }
} finally { Pop-Location }
Write-Host "`nPushed. Watch GitHub -> Actions; then open https://www.voltixstudio.com and use Stream Now -> Web Client." -ForegroundColor Green
