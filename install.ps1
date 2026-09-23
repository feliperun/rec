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
$checksumAsset = $release.assets | Where-Object name -eq "$assetName.sha256"
if (-not $checksumAsset) {
    throw "could not find '$assetName.sha256' in $releaseUrl"
}

# The JSON comes from api.github.com over TLS, but only trust a release
# download under this repository; anything else is refused before fetching.
$downloadPrefix = "https://github.com/$repo/releases/download/"
if (-not $asset.browser_download_url.StartsWith($downloadPrefix)) {
    throw "refusing to download '$assetName' from unexpected URL: $($asset.browser_download_url)"
}
if (-not $checksumAsset.browser_download_url.StartsWith($downloadPrefix)) {
    throw "refusing to download '$assetName.sha256' from unexpected URL: $($checksumAsset.browser_download_url)"
}

$installDir = "$env:LOCALAPPDATA\Programs\rec"
New-Item -ItemType Directory -Force $installDir | Out-Null

$dest = Join-Path $installDir "rec.exe"
Write-Host "Downloading $($asset.browser_download_url)..."
Invoke-WebRequest $asset.browser_download_url -OutFile $dest

# Verify the published <artifact>.sha256 (lowercase hex, two spaces, basename,
# LF) with Get-FileHash before the binary is ever executed.
$checksumPath = Join-Path ([System.IO.Path]::GetTempPath()) "$assetName.sha256"
try {
    Invoke-WebRequest $checksumAsset.browser_download_url -OutFile $checksumPath
    $checksumText = Get-Content -Raw -Path $checksumPath
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $checksumPath
}

$match = [regex]::Match([string]$checksumText, '^([0-9a-f]{64})  (\S+)\r?\n$')
if (-not $match.Success) {
    Remove-Item -Force -ErrorAction SilentlyContinue $dest
    throw "malformed checksum for '$assetName' in $($checksumAsset.browser_download_url)"
}
$expectedHash = $match.Groups[1].Value
$checksumFile = $match.Groups[2].Value
if ($checksumFile -ne $assetName) {
    Remove-Item -Force -ErrorAction SilentlyContinue $dest
    throw "checksum file names '$checksumFile', expected '$assetName'"
}
$actualHash = (Get-FileHash -Algorithm SHA256 -Path $dest).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    Remove-Item -Force -ErrorAction SilentlyContinue $dest
    throw "checksum mismatch for '$assetName' (expected $expectedHash, got $actualHash)"
}
Write-Host "Verified $assetName checksum."

# Persist to the user PATH (not the session copy); PowerShell's -like match
# keeps this idempotent across re-runs.
if (($env:PATH -split ";") -notcontains $installDir) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    [Environment]::SetEnvironmentVariable("Path", "$installDir;$userPath", "User")
    Write-Host "Added $installDir to your PATH - restart your shell to use rec"
}

Write-Host "Installed rec to $dest"

# Same trap as the POSIX installer: the shell runs the first rec.exe on PATH,
# so an older copy ahead of $installDir keeps answering after a clean install.
$found = (Get-Command rec -ErrorAction SilentlyContinue).Source
if ($found -and $found -ne $dest) {
    Write-Warning "$found is earlier on your PATH and runs instead of $dest"
}

& $dest --help
