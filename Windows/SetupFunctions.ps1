<#
.SYNOPSIS
    Shared functions and utilities for Windows setup scripts.

.DESCRIPTION
    This module contains common functions used across multiple Windows setup scripts.
    It provides logging, file download, GitHub API access, and other utility functions.
    This file should be dot-sourced at the beginning of scripts that need these functions.

.NOTES
    File Name: SetupFunctions.ps1
    Author: AlmostLight
    License: As-is
#>

# Ensure ConsoleNative P/Invoke types are available
if (-not ('WindowsSetup.ConsoleNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace WindowsSetup {
    public static class ConsoleNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleMode(IntPtr handle, uint mode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SystemParametersInfo(
            uint action,
            uint parameter,
            string value,
            uint winIni);
    }
}
'@
}

function Write-SetupLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Msg,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'WHATIF')]
        [string]$Type = 'INFO',
        [string]$LogPath,
        [switch]$WhatIf
    )
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Type] $Msg"
    Write-Host $Line
    if (-not $WhatIf -and $LogPath) {
        $LogDir = Split-Path $LogPath -Parent
        if ($LogDir -and (Test-Path $LogDir -PathType Container)) {
            Add-Content -Path $LogPath -Value $Line
        }
    }
}

function Read-TimedChoice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Prompt,
        [Parameter(Mandatory)]
        [string]$Default,
        [int]$TimeoutSeconds = 5
    )
    if ([Console]::IsInputRedirected) {
        return $Default
    }
    $InputHandle = [WindowsSetup.ConsoleNative]::GetStdHandle(-10)
    [uint32]$OriginalMode = 0
    $RestoreConsoleMode = $InputHandle -ne [IntPtr]::Zero -and
        [WindowsSetup.ConsoleNative]::GetConsoleMode($InputHandle, [ref]$OriginalMode)
    if ($RestoreConsoleMode) {
        $NoQuickEditMode = [uint32](($OriginalMode -bor 0x0080) -band 0xFFFFFFBF)
        if (-not [WindowsSetup.ConsoleNative]::SetConsoleMode($InputHandle, $NoQuickEditMode)) {
            $RestoreConsoleMode = $False
        }
    }
    try {
        $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $LastShown = -1
        while ($True) {
            $Remaining = [Math]::Max(0, [Math]::Ceiling(
                ($Deadline - [DateTime]::UtcNow).TotalSeconds
            ))
            if ($Remaining -ne $LastShown) {
                [Console]::Write("`r$Prompt [$Remaining] ")
                $LastShown = $Remaining
            }
            if ([Console]::KeyAvailable) {
                $Key = [Console]::ReadKey($True)
                if ($Key.Key -eq [ConsoleKey]::Enter) {
                    [Console]::WriteLine("`r$Prompt [$Remaining] $Default")
                    return $Default
                }
                if (-not [char]::IsControl($Key.KeyChar)) {
                    [Console]::WriteLine("`r$Prompt [$Remaining] $($Key.KeyChar)")
                    return [string]$Key.KeyChar
                }
            }
            if ([DateTime]::UtcNow -ge $Deadline) {
                [Console]::WriteLine("`r$Prompt [0] $Default")
                return $Default
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        if ($RestoreConsoleMode) {
            [WindowsSetup.ConsoleNative]::SetConsoleMode($InputHandle, $OriginalMode) | Out-Null
        }
    }
}

function Invoke-Step {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,
        [string]$LogPath,
        [switch]$WhatIf,
        [ref]$HadErrors
    )
    Write-SetupLog -Msg "RUN: $Name" -Type 'INFO' -LogPath $LogPath -WhatIf:$WhatIf
    if ($WhatIf) {
        Write-SetupLog -Msg "WHATIF: Would run $Name" -Type 'WHATIF' -LogPath $LogPath -WhatIf:$False
        return
    }
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        & $ScriptBlock
    } catch {
        Write-SetupLog -Msg "FAILED: $Name - $_" -Type 'ERROR' -LogPath $LogPath -WhatIf:$False
        if ($HadErrors) {
            $HadErrors.Value = $True
        }
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
}

function Write-Phase {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$LogPath
    )
    Write-SetupLog -Msg "PHASE: $Name" -Type 'INFO' -LogPath $LogPath
}

function Get-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$Out,
        [string]$ExpectedSha256,
        [string]$WorkPath = $Env:TEMP
    )
    $DownloadPath = Join-Path $WorkPath ([IO.Path]::GetFileName($Out) + ".$PID.download")
    for ($I = 0; $I -lt 3; $I++) {
        try {
            Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest $Url -OutFile $DownloadPath -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
            $Download = Get-Item $DownloadPath -ErrorAction Stop
            if ($Download.Length -eq 0) {
                throw "Downloaded file was empty: $Url"
            }
            if ($ExpectedSha256) {
                $ActualSha256 = (Get-FileHash $DownloadPath -Algorithm SHA256).Hash
                if ($ActualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
                    throw "SHA-256 mismatch for $Url. Expected $ExpectedSha256, got $ActualSha256"
                }
            }
            Move-Item $DownloadPath $Out -Force -ErrorAction Stop
            return
        } catch {
            if ($I -eq 2) {
                throw "Download failed after 3 attempts: $Url - $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-LatestGitHubAsset {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Repository,
        [string]$AssetName,
        [string]$AssetPattern
    )
    $ApiUrl = "https://api.github.com/repos/$Repository/releases/latest"
    $Release = Invoke-RestMethod -Uri $ApiUrl -Headers @{'User-Agent' = 'WindowsSetup'} -ErrorAction Stop
    $Asset = $Null
    if ($AssetName) {
        $Asset = $Release.assets | Where-Object name -eq $AssetName | Select-Object -First 1
    } elseif ($AssetPattern) {
        $Asset = $Release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    }
    if (-not $Asset) {
        $PatternUsed = if ($AssetName) { $AssetName } else { $AssetPattern }
        throw "GitHub release asset was not found: $Repository/$PatternUsed"
    }
    [pscustomobject]@{
        Url = $Asset.browser_download_url
        Sha256 = if ($Asset.digest -match '^sha256:([a-f0-9]{64})$') {
            $Matches[1]
        } else {
            $Null
        }
    }
}

function Restart-ExplorerShell {
    Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
    Start-Process -FilePath (Join-Path $Env:WINDIR 'explorer.exe') -ArgumentList '/factory' -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function Set-SymbolicLink {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Target
    )
    $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($TargetItem) {
        Remove-Item -LiteralPath $Target -Force -ErrorAction Stop
    }
    New-Item -ItemType SymbolicLink -Path $Target -Target $Source -ErrorAction Stop | Out-Null
}
