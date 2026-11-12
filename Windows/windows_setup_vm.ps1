<#
.SYNOPSIS
    VM-specific Windows setup for GPU passthrough guests.

.DESCRIPTION
    This script performs VM-specific setup including:
    - Winget installation
    - Package installation (WinFsp)
    - VirtIO drivers installation
    - Looking Glass installation
    - Virtual Display Driver (VDD) installation
    - Display Driver Uninstaller (DDU) download

.PARAMETER WhatIf
    If specified, shows what would be done without making any changes.

.EXAMPLE
    .\windows_setup_vm.ps1
    Runs the VM-specific Windows setup.

.EXAMPLE
    .\windows_setup_vm.ps1 -WhatIf
    Shows what would be configured without making changes.

.NOTES
    File Name: windows_setup_vm.ps1
    Author: AlmostLight
    License: As-is
    
    The script requires administrator privileges and will self-elevate if needed.
    Logs are written to %USERPROFILE%\scripts\vm-setup.<timestamp>.log
#>

[CmdletBinding()]
param (
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$ScriptUrl = 'https://raw.githubusercontent.com/almostlight/WindowsSetup/main/Windows/windows_setup_vm.ps1'

# Load shared functions
$ModuleRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
. (Join-Path $ModuleRoot 'SetupFunctions.ps1')

# --- Self-elevation ---
if (-not $WhatIf -and -not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $ElevatedScript = Join-Path $Env:TEMP "vm-setup-$PID.ps1"
    $ElevatedFunctionsScript = Join-Path $Env:TEMP 'SetupFunctions.ps1'
    if ($PSCommandPath -and (Test-Path $PSCommandPath -PathType Leaf)) {
        Copy-Item $PSCommandPath $ElevatedScript -Force
        $SetupFunctionsSource = Join-Path $PSScriptRoot 'SetupFunctions.ps1'
        if (Test-Path $SetupFunctionsSource -PathType Leaf) {
            Copy-Item $SetupFunctionsSource $ElevatedFunctionsScript -Force
        }
    } else {
        Invoke-WebRequest $ScriptUrl -OutFile $ElevatedScript -UseBasicParsing
        Get-RawRepositoryFile -RelativePath 'Windows/SetupFunctions.ps1' -Out $ElevatedFunctionsScript
    }

    $Shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $Shell) {
        $Shell = (Get-Command powershell.exe).Source
    }
    
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ElevatedScript`""
    if ($WhatIf) {
        $Arguments += ' -WhatIf'
    }
    

    $Process = Start-Process $Shell -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
    Remove-Item $ElevatedScript -Force -ErrorAction SilentlyContinue
    exit $Process.ExitCode
}

$Date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$BasePath = [Environment]::GetFolderPath('UserProfile')
$Downloads = Join-Path $BasePath 'Downloads'
$ScriptsPath = Join-Path $BasePath 'scripts'
$LogPath = Join-Path $ScriptsPath "vm-setup.$(Get-Date -Format 'yyyy-MM-dd_HH_mm_ss').log"

New-Item -ItemType Directory -Force -Path $Downloads, $ScriptsPath | Out-Null

function Write-Log {
    param (
        [string]$Msg,
        [string]$Type = 'INFO'
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $Line
    Add-Content -Path $LogPath -Value $Line
}

Write-Log -Msg 'Starting VM provisioning'

function Run-Step {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock
    )

    Write-Log -Msg "RUN: $Name"

    if ($WhatIf) {
        return
    }

    try {
        & $ScriptBlock
    } catch {
        Write-Log -Msg "FAILED: $Name - $_" -Type 'ERROR'
    }
}

function Get-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$Out
    )

    if (Test-Path $Out) {
        return
    }

    for ($I = 0; $I -lt 3; $I++) {
        try {
            Invoke-WebRequest $Url -OutFile $Out -TimeoutSec 60
            return
        } catch {
            Start-Sleep -Seconds 2
        }
    }

    throw "Download failed: $Url"
}

function Install-Package {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Id
    )

    $Installed = & winget list --exact --id $Id `
        --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($Installed -match '(?im)\b$([regex]::Escape($Id))\b') {
        Write-Log -Msg "Skipping already installed package $Id"
        return
    }

    Write-Log -Msg "Installing $Id"
    & winget install -e --id $Id --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Winget failed for $Id with exit code $LASTEXITCODE"
    }
}

function Get-LatestGitHubRelease {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$AssetPattern
    )

    $Api = "https://api.github.com/repos/$Repo/releases/latest"
    $Release = Invoke-RestMethod -Uri $Api -Headers @{
        'User-Agent' = 'PowerShell'
    }
    $Asset = $Release.Assets |`
        Where-Object { $_.Name -like $AssetPattern } |`
        Select-Object -First 1

    if (-not $Asset) {
        throw "No asset matching $AssetPattern in $Repo"
    }

    return $Asset.Browser_download_url
}

Run-Step -Name 'winget' -ScriptBlock {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $Pkg = Join-Path $Downloads 'winget.msixbundle'
        Get-File -Url 'https://aka.ms/getwinget' -Out $Pkg
        Add-AppxPackage $Pkg
        Start-Sleep -Seconds 5
    }
}

Run-Step -Name 'packages' -ScriptBlock {
    Install-Package -Id 'WinFsp.WinFsp'
}

Run-Step -Name 'virtio' -ScriptBlock {
    $File = Join-Path $Downloads 'virtio.exe'
    Get-File -Url 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe' -Out $File
    Start-Process $File -ArgumentList '/quiet' -Wait
}

Run-Step -Name 'lookingglass' -ScriptBlock {
    $LgDir = Join-Path $Downloads 'lg'
    $Existing = if (Test-Path $LgDir) {
        Get-ChildItem $LgDir -Recurse -Filter 'looking-glass-host-setup.exe' |`
            Select-Object -First 1
    }

    if ($Existing) {
        Write-Log -Msg 'Looking Glass already extracted/available, skipping download' -Type 'SUCCESS'
        Start-Process $Existing.FullName -Wait
        return
    }

    $Zip = Join-Path $Downloads 'lg.zip'
    Get-File -Url 'https://looking-glass.io/artifact/stable/host' -Out $Zip
    Expand-Archive $Zip $LgDir -Force

    $Exe = Get-ChildItem $LgDir -Recurse -Filter 'looking-glass-host-setup.exe' |`
        Select-Object -First 1
    if ($Exe) {
        Start-Process $Exe.FullName -Wait
    }
}

Run-Step -Name 'vdd' -ScriptBlock {
    $VddInstallPath = 'C:\Program Files\VDD_Control'
    $VddExe = Get-ChildItem $VddInstallPath -Recurse -Filter 'VDD Control.exe' `
        -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($VddExe) {
        Write-Log -Msg "VDD already installed at $($VddExe.FullName), skipping download/install" -Type 'SUCCESS'
        return
    }

    New-Item $VddInstallPath -ItemType Directory -Force | Out-Null
    $VddUrl = Get-LatestGitHubRelease `
        -Repo 'VirtualDrivers/Virtual-Display-Driver' `
        -AssetPattern 'VDD.Control.*.zip'
    $Zip = Join-Path $Env:TEMP 'vdd.zip'
    Invoke-WebRequest $VddUrl -OutFile $Zip
    Expand-Archive $Zip $VddInstallPath -Force
    Remove-Item $Zip -Force

    $Exe = Get-ChildItem $VddInstallPath -Recurse -Filter 'VDD Control.exe' |`
        Select-Object -First 1
    if ($Exe) {
        Start-Process $Exe.FullName
    }
}

Run-Step -Name 'ddu' -ScriptBlock {
    $Path = Join-Path $Downloads 'DDU.exe'
    Invoke-WebRequest 'https://www.wagnardsoft.com/DDU/download/DDU%20v18.0.8.5.exe' -OutFile $Path
}

Write-Log -Msg 'VM provisioning complete'
