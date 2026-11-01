param(
    [switch]$BarWatchdog
)

$ErrorActionPreference = "Stop"

$BasePath = [Environment]::GetFolderPath("UserProfile")
$ProgramFiles = ${env:ProgramFiles}

$komorebic = Join-Path $ProgramFiles "komorebi\bin\komorebic.exe"
$autoHotkey = Join-Path $ProgramFiles "AutoHotkey\v2\AutoHotkey.exe"
$processPriority = [Diagnostics.ProcessPriorityClass]::High

if ($BarWatchdog) {
    $bar = Join-Path $ProgramFiles "komorebi\bin\komorebi-bar.exe"
    $mutex = New-Object Threading.Mutex($false, "WindowsSetup.KomorebiBarWatchdog")
    $ownsMutex = $false

    try {
        try {
            $ownsMutex = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            return
        }

        while ($true) {
            if (-not (Get-Process -Name "komorebi" -ErrorAction SilentlyContinue)) {
                try {
                    Start-Process $komorebic `
                        -ArgumentList @("start", "--whkd", "--bar") `
                        -WorkingDirectory $BasePath `
                        -WindowStyle Hidden `
                        -ErrorAction Stop
                } catch {
                    Write-Error "Could not start komorebi: $($_.Exception.Message)"
                }
            }

            if (-not (Get-Process -Name "komorebi-bar" -ErrorAction SilentlyContinue)) {
                try {
                    Start-Process $bar `
                        -WorkingDirectory $BasePath `
                        -WindowStyle Hidden `
                        -ErrorAction Stop
                } catch {
                    Write-Error "Could not start komorebi-bar: $($_.Exception.Message)"
                }
            }

            foreach ($process in (Get-Process -Name @("komorebi", "whkd") -ErrorAction SilentlyContinue)) {
                try {
                    $process.PriorityClass = $processPriority
                } catch {
                    Write-Error "Could not set priority for $($process.ProcessName): $($_.Exception.Message)"
                }
            }

            Start-Sleep -Seconds 2
        }
    } finally {
        if ($ownsMutex) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
    return
}

function Set-StartupProcessPriority {
    param(
        [string[]]$Names
    )

    foreach ($process in (Get-Process -Name $Names -ErrorAction SilentlyContinue)) {
        $process.PriorityClass = $processPriority
    }
}

Set-StartupProcessPriority @("komorebi", "whkd")

$autoHotkeyProcesses = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
if (-not $autoHotkeyProcesses) {
    Start-Process $autoHotkey `
        -ArgumentList (Join-Path $BasePath "scripts\autohotkey\master.ahk") `
        -WorkingDirectory (Join-Path $BasePath "scripts\autohotkey") `
        -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    $autoHotkeyProcesses = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
}

Set-StartupProcessPriority "AutoHotkey*"

# taskkill /f /im explorer.exe      # this is buggy    
