# VM-specific Windows setup for GPU passthrough guests.
param(
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ScriptUrl = "https://raw.githubusercontent.com/almostlight/WindowsSetup/main/Windows/windows_setup_vm.ps1"

# --- Self-elevation ---
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $elevatedScript = Join-Path $env:TEMP "vm-setup-$PID.ps1"
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $elevatedScript -Force
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $elevatedScript -UseBasicParsing
    }

    $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $shell) { $shell = (Get-Command powershell.exe).Source }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`""
    if ($WhatIf) { $arguments += " -WhatIf" }
    $process = Start-Process $shell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    Remove-Item $elevatedScript -Force -ErrorAction SilentlyContinue
    exit $process.ExitCode
}

# --- Core paths ---
$date = Get-Date -Format "yyyy-MM-dd_HH_mm_ss"
$BasePath = [Environment]::GetFolderPath("UserProfile")
$Downloads = Join-Path $BasePath "Downloads"
$ScriptsPath = Join-Path $BasePath "scripts"
$LogPath = Join-Path $ScriptsPath "vm-setup.$date.log"

New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath | Out-Null

# --- Logging ---
function Write-Log {
    param($Msg, $Type="INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $line
    Add-Content $LogPath $line
}

Write-Log "Starting VM provisioning"

function Run-Step($Name, $ScriptBlock) {
    Write-Log "RUN: $Name"

    if ($WhatIf) { return }

    try {
        & $ScriptBlock
    } catch {
        Write-Log "FAILED: $Name - $_" "ERROR"
    }
}

function Get-File($Url, $Out) {
    if (Test-Path $Out) { return }

    for ($i = 0; $i -lt 3; $i++) {
        try {
            Invoke-WebRequest $Url -OutFile $Out -TimeoutSec 60
            return
        } catch {
            Start-Sleep 2
        }
    }

    throw "Download failed: $Url"
}

function Install-Package($id) {
    $installed = & winget list --exact --id $id `
        --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($installed -match "(?im)\b$([regex]::Escape($id))\b") {
        Write-Log "Skipping already installed package $id"
        return
    }

    Write-Log "Installing $id"
    & winget install -e --id $id --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Winget failed for $id with exit code $LASTEXITCODE"
    }
}

function Get-LatestGitHubRelease {
    param(
        [string]$Repo,
        [string]$AssetPattern
    )

    $api = "https://api.github.com/repos/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $api -Headers @{
        "User-Agent" = "PowerShell"
    }
    $asset = $release.assets |
        Where-Object { $_.name -like $AssetPattern } |
        Select-Object -First 1

    if (-not $asset) {
        throw "No asset matching $AssetPattern in $Repo"
    }

    return $asset.browser_download_url
}

Run-Step "winget" {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $Downloads "winget.msixbundle"
        Get-File "https://aka.ms/getwinget" $pkg
        Add-AppxPackage $pkg
        Start-Sleep 5
    }
}

Run-Step "packages" {
    Install-Package "WinFsp.WinFsp"
}

Run-Step "virtio" {
    $file = Join-Path $Downloads "virtio.exe"
    Get-File "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe" $file
    Start-Process $file -ArgumentList "/quiet" -Wait
}

Run-Step "lookingglass" {
    $lgDir = Join-Path $Downloads "lg"
    $existing = if (Test-Path $lgDir) {
        Get-ChildItem $lgDir -Recurse -Filter "looking-glass-host-setup.exe" |
            Select-Object -First 1
    }

    if ($existing) {
        Write-Log "Looking Glass already extracted/available, skipping download" "SUCCESS"
        Start-Process $existing.FullName -Wait
        return
    }

    $zip = Join-Path $Downloads "lg.zip"
    Get-File "https://looking-glass.io/artifact/stable/host" $zip
    Expand-Archive $zip $lgDir -Force

    $exe = Get-ChildItem $lgDir -Recurse -Filter "looking-glass-host-setup.exe" |
        Select-Object -First 1
    if ($exe) { Start-Process $exe.FullName -Wait }
}

Run-Step "vdd" {
    $vddInstallPath = "C:\Program Files\VDD_Control"
    $vddExe = Get-ChildItem $vddInstallPath -Recurse -Filter "VDD Control.exe" `
        -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($vddExe) {
        Write-Log "VDD already installed at $($vddExe.FullName), skipping download/install" "SUCCESS"
        return
    }

    New-Item $vddInstallPath -ItemType Directory -Force | Out-Null
    $vddUrl = Get-LatestGitHubRelease `
        -Repo "VirtualDrivers/Virtual-Display-Driver" `
        -AssetPattern "VDD.Control.*.zip"
    $zip = Join-Path $env:TEMP "vdd.zip"
    Invoke-WebRequest $vddUrl -OutFile $zip
    Expand-Archive $zip $vddInstallPath -Force
    Remove-Item $zip -Force

    $exe = Get-ChildItem $vddInstallPath -Recurse -Filter "VDD Control.exe" |
        Select-Object -First 1
    if ($exe) { Start-Process $exe.FullName }
}

# =========================
# DDU
# =========================

Run-Step "ddu" {
    $path = Join-Path $Downloads "DDU.exe"
    Invoke-WebRequest "https://www.wagnardsoft.com/DDU/download/DDU%20v18.0.8.5.exe" -OutFile $path
}

Write-Log "VM provisioning complete"
