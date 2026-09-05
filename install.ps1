# Installs a release of rec (https://github.com/feliperun/rec) to
# $env:LOCALAPPDATA\Programs\rec and adds it to the user PATH. Usage:
#
#   irm https://raw.githubusercontent.com/feliperun/rec/main/install.ps1 | iex
#
# Override: $env:VERSION = "<tag>" installs that release instead of the latest.
$ErrorActionPreference = "Stop"

$repo = "feliperun/rec"
$assetName = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "rec-windows-x64.exe" }
    default { throw "no rec build for this architecture ($($env:PROCESSOR_ARCHITECTURE)); x64 Windows only" }
}

$releaseUrl = "https://api.github.com/repos/$repo/releases/latest"
if ($env:VERSION) {
    $releaseUrl = "https://api.github.com/repos/$repo/releases/tags/$($env:VERSION)"
}

$release = Invoke-RestMethod $releaseUrl
$asset = $release.assets | Where-Object name -eq $assetName
if (-not $asset) {
    throw "could not find '$assetName' in $releaseUrl"
}

$installDir = "$env:LOCALAPPDATA\Programs\rec"
New-Item -ItemType Directory -Force $installDir | Out-Null

$dest = Join-Path $installDir "rec.exe"
Write-Host "Downloading $($asset.browser_download_url)..."
Invoke-WebRequest $asset.browser_download_url -OutFile $dest

# Persist to the user PATH (not the session copy); PowerShell's -like match
# keeps this idempotent across re-runs.
if (($env:PATH -split ";") -notcontains $installDir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    [Environment]::SetEnvironmentVariable("Path", "$installDir;$userPath", "User")
    Write-Host "Added $installDir to your PATH - restart your shell to use rec"
}

Write-Host "Installed rec to $dest"
& $dest --help
