# Mesh Downloader setup (offline)
# Copies the app files from this folder to a folder you choose (any drive),
# moves your downloads over from an older install, then opens the app.
# Nothing is downloaded here - the app updates itself later.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$src     = $PSScriptRoot
$appData = Join-Path $env:APPDATA 'RobloxMeshDownloader'
$marker  = Join-Path $appData 'install.txt'

Write-Host ''
Write-Host '  Mesh Downloader Setup' -ForegroundColor Cyan
Write-Host ''

# The app has to be closed so its files can be replaced
$running = $null
try { $running = [System.Threading.Mutex]::OpenExisting('Local\RobloxMeshDownloader') } catch { }
if ($running) {
    $running.Dispose()
    Write-Host '  Close Mesh Downloader first, then run Setup again.' -ForegroundColor Yellow
    exit 3
}

$info = Get-Content -LiteralPath (Join-Path $src 'version.json') -Raw | ConvertFrom-Json

# Where is it installed now (if anywhere)?
$old = $null
if (Test-Path -LiteralPath $marker) { $old = (Get-Content -LiteralPath $marker -Raw).Trim() }
if (-not $old) {
    $d = Join-Path $env:LOCALAPPDATA 'Programs\Mesh Downloader'
    if (Test-Path -LiteralPath (Join-Path $d 'RobloxMeshDownloader.ps1')) { $old = $d }
}
if ($old -and -not (Test-Path -LiteralPath (Join-Path $old 'RobloxMeshDownloader.ps1'))) { $old = $null }

# Ask where to install
Write-Host '  Pick where to install (the folder window may be behind this one).'
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.StartPosition = 'CenterScreen'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Show(); $owner.Hide()
$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
$dlg.Description = 'Choose where to install Mesh Downloader. A "Mesh Downloader" folder is made inside the folder you pick, and your downloaded meshes and models are saved there too.'
$dlg.ShowNewFolderButton = $true
if ($old) { $dlg.SelectedPath = Split-Path $old -Parent }
$res = $dlg.ShowDialog($owner)
$owner.Dispose()
if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host '  Setup cancelled - nothing was changed.'
    exit 2
}
$pick = $dlg.SelectedPath.TrimEnd('\')
if ((Split-Path $pick -Leaf) -eq 'Mesh Downloader') { $dest = $pick } else { $dest = Join-Path $pick 'Mesh Downloader' }
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Write-Host "  Installing v$($info.version) to $dest"

# Copy the app files
$full = { param($p) [IO.Path]::GetFullPath($p).TrimEnd('\') }
if ((& $full $src) -ne (& $full $dest)) {
    foreach ($f in (@($info.files) + @($info.installOnly))) {
        $name = [IO.Path]::GetFileName([string]$f)
        $from = Join-Path $src $name
        if (-not $name -or -not (Test-Path -LiteralPath $from)) { continue }
        Write-Host "    $name"
        Copy-Item -LiteralPath $from -Destination (Join-Path $dest $name) -Force
    }
}
# Files from a downloaded zip are marked "from the internet"; clear that so Windows doesn't ask every time.
Get-ChildItem -LiteralPath $dest -File | Unblock-File

# Moving from an older install? Bring the library + downloads along, then remove the old copy.
if ($old -and ((& $full $old) -ne (& $full $dest))) {
    Write-Host "  Moving your meshes and models from $old ..."
    foreach ($item in 'library', 'library.json', 'Roblox Meshes') {
        $from = Join-Path $old $item
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $target = Join-Path $dest $item
        if ((Get-Item -LiteralPath $from).PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $from '*') -Destination $target -Recurse -Force
        } else {
            Copy-Item -LiteralPath $from -Destination $target -Force
        }
    }
    $settingsFile = Join-Path $appData 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $st = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
            if ($st.folder -and ([string]$st.folder).StartsWith($old, [StringComparison]::OrdinalIgnoreCase)) {
                $st.folder = $dest + ([string]$st.folder).Substring($old.Length)
                $st | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
            }
        } catch { }
    }
    try {
        Remove-Item -LiteralPath $old -Recurse -Force
        Write-Host '  Removed the old install.'
    } catch {
        Write-Host "  Couldn't remove the old folder ($old) - you can delete it yourself." -ForegroundColor Yellow
    }
}

New-Item -ItemType Directory -Path $appData -Force | Out-Null
Set-Content -LiteralPath $marker -Value $dest

Write-Host ''
Write-Host '  Installed!' -ForegroundColor Green
Write-Host '  Opening Mesh Downloader - it adds a Desktop + Start menu icon on first run.'
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $dest 'RobloxMeshDownloader.ps1') + '"')
exit 0
