# Mesh Downloader installer - downloads the latest version from GitHub
# into %LOCALAPPDATA%\Programs\Mesh Downloader and opens it.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = 'https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Mesh Downloader'
$stamp = [DateTime]::UtcNow.Ticks

Write-Host ''
Write-Host '  Installing Mesh Downloader...' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $dest -Force | Out-Null

$info = Invoke-RestMethod -UseBasicParsing -Uri "$base/version.json?t=$stamp"
foreach ($f in @($info.files)) {
    $name = [IO.Path]::GetFileName([string]$f)
    if (-not $name) { continue }
    Write-Host "    $name"
    Invoke-WebRequest -UseBasicParsing -Uri ("$base/" + [Uri]::EscapeDataString($name) + "?t=$stamp") -OutFile (Join-Path $dest $name)
}

Write-Host ''
Write-Host "  Installed v$($info.version) to $dest" -ForegroundColor Green
Write-Host '  Opening Mesh Downloader - it adds a Desktop + Start menu icon on first run.'
Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dest 'Mesh Downloader.vbs') + '"')
