param(
    [switch]$BarWatchdog
)

$ErrorActionPreference = "Stop"

$BasePath = [Environment]::GetFolderPath("UserProfile")
$ProgramFiles = ${env:ProgramFiles}

$komorebic = Join-Path $ProgramFiles "komorebi\bin\komorebic.exe"
$autoHotkey = Join-Path $ProgramFiles "AutoHotkey\v2\AutoHotkey.exe"
$powerToys = Join-Path $env:LOCALAPPDATA "PowerToys\PowerToys.exe"
$processPriority = [Diagnostics.ProcessPriorityClass]::High

if ($BarWatchdog) {
    $bar = Join-Path $ProgramFiles "komorebi\bin\komorebi-bar.exe"
    $barConfigs = @(
        (Join-Path $BasePath "komorebi.bar.json"),
        (Join-Path $BasePath "komorebi.bar.1.json")
    )
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
                        -ArgumentList @("start", "--whkd") `
                        -WorkingDirectory $BasePath `
                        -WindowStyle Hidden `
                        -ErrorAction Stop
                } catch {
                    Write-Error "Could not start komorebi: $($_.Exception.Message)"
                }
            }

            $barProcesses = @(Get-Process -Name "komorebi-bar" -ErrorAction SilentlyContinue)
            for ($index = 0; $index -lt $barConfigs.Count; $index++) {
                if ($barProcesses.Count -le $index) {
                    $barConfig = $barConfigs[$index]
                    if (-not (Test-Path $barConfig -PathType Leaf)) {
                        Write-Error "Komorebi bar configuration was not found: $barConfig"
                        continue
                    }

                try {
                    Start-Process $bar `
                        -ArgumentList @("--config", $barConfig) `
                        -WorkingDirectory $BasePath `
                        -WindowStyle Hidden `
                        -ErrorAction Stop
                } catch {
                    Write-Error "Could not start komorebi-bar for monitor $index`: $($_.Exception.Message)"
                }
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

$powerToysProcesses = Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue
if (-not $powerToysProcesses) {
    if (-not (Test-Path $powerToys -PathType Leaf)) {
        Write-Error "PowerToys executable was not found: $powerToys"
    } else {
        Start-Process $powerToys `
            -WorkingDirectory (Split-Path $powerToys) `
            -WindowStyle Hidden `
            -ErrorAction Stop
    }
}

$masterScript = Join-Path $BasePath "scripts\autohotkey\master.ahk"
$masterScriptRunning = Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$masterScript*" }
if (-not $masterScriptRunning) {
    if (-not (Test-Path $autoHotkey -PathType Leaf)) {
        throw "AutoHotkey executable was not found: $autoHotkey"
    }
    if (-not (Test-Path $masterScript -PathType Leaf)) {
        throw "AutoHotkey script was not found: $masterScript"
    }

    Start-Process $autoHotkey `
        -ArgumentList $masterScript `
        -WorkingDirectory (Split-Path $masterScript) `
        -WindowStyle Hidden `
        -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    $masterScriptRunning = Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$masterScript*" }
    if (-not $masterScriptRunning) {
        throw "AutoHotkey did not start from $masterScript"
    }
}

Set-StartupProcessPriority "AutoHotkey*"

# taskkill /f /im explorer.exe      # this is buggy    
