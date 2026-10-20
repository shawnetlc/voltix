<#
  Builds the customer-ready "Voltix TV Installer" zip for Samsung (Tizen) TVs.

  The zip contains:
    Voltix_Tizen_v<ver>.tpk   - the build (signed with your DUID certificate)
    sdb.exe                   - Samsung's install tool (from Tizen Studio)
    Install-Voltix.ps1        - the installer (scan, checks, install, DUID)
    Install Voltix.bat        - what the customer double-clicks
    Installation Guide.html   - step-by-step guide with prerequisites

  Usage:
    .\package-tizen-installer.ps1                         (newest .tpk in build\tizen\tpk)
    .\package-tizen-installer.ps1 -TpkPath .\Voltix_Tizen_v2.0.62.tpk
    .\package-tizen-installer.ps1 -Customer "Shawne-Lounge"   (adds a label to the zip name)

  Called automatically at the end of build-tizen.ps1 (skip with -NoInstaller).
#>
[CmdletBinding()]
param(
  [string]$TpkPath,
  [string]$Version,
  [string]$SdbPath = $env:TIZEN_SDB,
  [string]$Customer,
  [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateDir = Join-Path $repoRoot 'tizen-installer'
if (-not $OutputDir) { $OutputDir = $repoRoot }

# --- the .tpk
if (-not $TpkPath) {
  $candidates = @(Get-ChildItem -Path (Join-Path $repoRoot 'build\tizen\tpk') -Filter '*.tpk' -ErrorAction SilentlyContinue)
  if ($candidates.Count -eq 0) { $candidates = @(Get-ChildItem -Path $repoRoot -Filter 'Voltix_Tizen_v*.tpk' -ErrorAction SilentlyContinue) }
  $TpkPath = ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $TpkPath -or -not (Test-Path $TpkPath)) { throw 'No .tpk found. Build first with .\build-tizen.ps1 or pass -TpkPath.' }

# --- version (from the tpk manifest when not given)
if (-not $Version) {
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $TpkPath))
    try {
      $entry = $zip.Entries | Where-Object { $_.FullName -eq 'tizen-manifest.xml' } | Select-Object -First 1
      if ($entry) { $sr = New-Object IO.StreamReader($entry.Open()); [xml]$x = $sr.ReadToEnd(); $sr.Close(); $Version = [string]$x.manifest.version }
    } finally { $zip.Dispose() }
  } catch {}
  if (-not $Version) { $Version = (Get-Date -Format 'yyyyMMdd') }
}

# --- sdb.exe
if (-not $SdbPath -or -not (Test-Path $SdbPath)) {
  $sdbCandidates = @(
    $(if ($env:TIZEN_STUDIO) { Join-Path $env:TIZEN_STUDIO 'tools\sdb.exe' }),
    'C:\tizen-studio\tools\sdb.exe',
    (Join-Path $env:USERPROFILE 'tizen-studio\tools\sdb.exe'),
    'D:\tizen-studio\tools\sdb.exe'
  ) | Where-Object { $_ -and (Test-Path $_) }
  $SdbPath = $sdbCandidates | Select-Object -First 1
  if (-not $SdbPath) { $cmd = Get-Command sdb.exe -ErrorAction SilentlyContinue; if ($cmd) { $SdbPath = $cmd.Source } }
}
if (-not $SdbPath -or -not (Test-Path $SdbPath)) {
  throw 'sdb.exe not found. Install Tizen Studio, or pass -SdbPath / set $env:TIZEN_SDB to ...\tizen-studio\tools\sdb.exe'
}

foreach ($f in @('Install-Voltix.ps1', 'Install Voltix.bat', 'Installation Guide.html')) {
  if (-not (Test-Path (Join-Path $templateDir $f))) { throw "Missing installer template: tizen-installer\$f" }
}

# --- stage
$label = if ($Customer) { '_' + ($Customer -replace '[^A-Za-z0-9\-]', '-') } else { '' }
$name = "Voltix_TV_Installer_v$Version$label"
$stage = Join-Path $repoRoot "build\tizen\installer\$name"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item $TpkPath (Join-Path $stage "Voltix_Tizen_v$Version.tpk")
Copy-Item $SdbPath (Join-Path $stage 'sdb.exe')
# sdb normally runs on its own; copy any sdb-specific DLLs that sit next to it just in case
Get-ChildItem -Path (Split-Path $SdbPath) -Filter 'libsdb*.dll' -ErrorAction SilentlyContinue | Copy-Item -Destination $stage
foreach ($f in @('Install-Voltix.ps1', 'Install Voltix.bat', 'Installation Guide.html')) {
  Copy-Item (Join-Path $templateDir $f) (Join-Path $stage $f)
}

# --- check the bundled sdb.exe runs without Tizen Studio on PATH
$savedPath = $env:PATH
try {
  $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
  $ver = & (Join-Path $stage 'sdb.exe') version 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $ver -notmatch '\d') { Write-Warning "Bundled sdb.exe did not run on its own: $ver" }
  else { Write-Host "   sdb.exe OK: $($ver.Trim())" -ForegroundColor DarkGray }
  & (Join-Path $stage 'sdb.exe') kill-server 2>&1 | Out-Null
} catch { Write-Warning "Could not test bundled sdb.exe: $($_.Exception.Message)" }
finally { $env:PATH = $savedPath }

# --- zip
$zipPath = Join-Path $OutputDir "$name.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "==> TV installer ready: $zipPath ($sizeMb MB)" -ForegroundColor Green
Write-Host '    Send this zip to the customer. It only installs on TVs whose DUID is in the signing certificate.' -ForegroundColor DarkGray
return $zipPath
