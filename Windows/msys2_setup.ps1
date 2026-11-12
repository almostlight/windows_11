<#
.SYNOPSIS
    Configures MSYS2 development environment with Mingw-w64 UCRT toolchain.

.DESCRIPTION
    This script installs and configures MSYS2 with the necessary development tools
    (gcc, g++, gdb, make) for the UCRT environment. It also updates the system PATH
    to include MSYS2 binaries.

.PARAMETER WhatIf
    If specified, shows what would be done without making any changes.

.EXAMPLE
    .\msys2_setup.ps1
    Configures MSYS2 development environment.

.EXAMPLE
    .\msys2_setup.ps1 -WhatIf
    Shows what would be configured without making changes.

.NOTES
    File Name: msys2_setup.ps1
    Prerequisite: MSYS2 must be installed at C:\msys64
    Author: AlmostLight
    License: As-is
#>

[CmdletBinding()]
param (
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Write-SetupLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Msg,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'WHATIF')]
        [string]$Type = 'INFO'
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $Line
    if (-not $WhatIf) {
        Add-Content -Path $Script:LogPath -Value $Line
    }
}

$Date = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$BasePath = [Environment]::GetFolderPath('UserProfile')
$ScriptsPath = Join-Path $BasePath 'scripts'
$LogPath = Join-Path $ScriptsPath 'msys2_setup.log'

if ($WhatIf) {
    Write-Host "[WHATIF] MSYS2 setup started: $Date"
} else {
    New-Item -ItemType Directory -Force -Path $ScriptsPath | Out-Null
    Set-Content -Path $LogPath -Value "MSYS2 setup started: $Date"
}

Write-SetupLog -Msg 'Starting MSYS2 configuration' -Type 'INFO'

try {
    $Msys2Path = 'C:\msys64'

    if (-not (Test-Path $Msys2Path)) {
        Write-SetupLog -Msg "MSYS2 not found at $Msys2Path, skipping configuration" -Type 'WARN'
        return
    }

    Write-SetupLog -Msg 'Configuring MSYS2 development environment...'

    $PacmanPath = Join-Path $Msys2Path 'usr\bin\pacman.exe'
    if (-not (Test-Path $PacmanPath)) {
        Write-SetupLog -Msg "pacman not found at $PacmanPath, skipping MSYS2 configuration" -Type 'WARN'
        return
    }

    Write-SetupLog -Msg 'Updating package database...'
    $UpdateArgs = '-Syu --noconfirm --disable-download-timeout'
    $UpdateProcess = Start-Process -FilePath $PacmanPath -ArgumentList $UpdateArgs -Wait -PassThru -NoNewWindow
    if ($UpdateProcess.ExitCode -ne 0) {
        Write-SetupLog -Msg "pacman update failed with exit code $($UpdateProcess.ExitCode)" -Type 'WARN'
    }

    Write-SetupLog -Msg 'Installing gcc, g++, gdb, make via pacman...'
    $PacmanArgs = '-S --needed --noconfirm --disable-download-timeout mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb mingw-w64-ucrt-x86_64-make'
    $Process = Start-Process -FilePath $PacmanPath -ArgumentList $PacmanArgs -Wait -PassThru -NoNewWindow
    if ($Process.ExitCode -ne 0) {
        Write-SetupLog -Msg "pacman installation failed with exit code $($Process.ExitCode)" -Type 'WARN'
    } else {
        Write-SetupLog -Msg 'MSYS2 toolchain installed successfully' -Type 'SUCCESS'
    }

    Write-SetupLog -Msg 'Verifying gcc, g++, gdb installations...'
    $UcrtBinPath = Join-Path $Msys2Path 'ucrt64\bin'
    $Tools = @('gcc.exe', 'g++.exe', 'gdb.exe', 'make.exe')
    $MissingTools = @()

    foreach ($Tool in $Tools) {
        $ToolPath = Join-Path $UcrtBinPath $Tool
        if (-not (Test-Path $ToolPath)) {
            $MissingTools += $Tool
            Write-SetupLog -Msg "MISSING: $ToolPath not found" -Type 'WARN'
        } else {
            Write-SetupLog -Msg "FOUND: $ToolPath" -Type 'SUCCESS'
        }
    }

    if ($MissingTools.Count -gt 0) {
        Write-SetupLog -Msg "WARNING: Missing tools: $($MissingTools -join ', ')" -Type 'WARN'
    }

    Write-SetupLog -Msg 'Configuring PATH for MSYS2...'
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $NewPaths = @(
        Join-Path $Msys2Path 'ucrt64\bin',
        Join-Path $Msys2Path 'mingw64\bin',
        Join-Path $Msys2Path 'usr\bin'
    )

    foreach ($NewPath in $NewPaths) {
        if ($UserPath -notlike "*$NewPath*") {
            $UserPath = "$NewPath;$UserPath"
        }
    }
    [Environment]::SetEnvironmentVariable('Path', $UserPath, 'User')

    $Env:Path = $UserPath

    Write-SetupLog -Msg 'MSYS2 PATH configuration complete' -Type 'INFO'
    Write-SetupLog -Msg 'Developer environment configured: MSYS2 with Mingw-w64 UCRT toolchain' -Type 'SUCCESS'

    Write-SetupLog -Msg 'MSYS2 configuration complete' -Type 'INFO'
} catch {
    Write-SetupLog -Msg "ERROR: $_" -Type 'ERROR'
    exit 1
}

if (-not $WhatIf) {
    Write-Host "MSYS2 setup log: $LogPath"
}
